import Foundation
private import os

/// Custom error for Pub/Sub HTTP failures, carrying the status code.
enum PubSubError: Error, Sendable {
    case httpError(statusCode: Int, data: Data)
    /// OAuth token lacks the `pubsub` scope — re-authorization can fix this.
    case insufficientScope(accountID: String)
    /// IAM permission denied or API disabled — re-authorization will NOT fix this.
    case permissionDenied(accountID: String, reason: String)
}

/// Pulls Gmail change notifications from a Google Cloud Pub/Sub subscription
/// and triggers incremental sync on the active `FullSyncEngine`.
actor PubSubService {

    nonisolated private static let logger = Logger(category: "PubSub")

    // MARK: - State

    private var pullTask: Task<Void, Never>?
    private var consecutiveFailures = 0
    private var activeEmail: String?
    private var activeEngine: FullSyncEngine?
    private(set) var tokenAccountID: String?
    private var debounceTask: Task<Void, Never>?
    private var scopeAlertPosted = false

    deinit {
        pullTask?.cancel()
        debounceTask?.cancel()
    }

    // MARK: - Account Management

    /// Sets the currently active engine (called on account switch).
    func setActiveEngine(email: String, engine: FullSyncEngine) {
        activeEmail = email
        activeEngine = engine
    }

    /// Clears the active engine reference.
    func clearActiveEngine() {
        activeEmail = nil
        activeEngine = nil
    }

    /// Updates which account's OAuth token is used for Pub/Sub pull requests.
    func setTokenAccountID(_ id: String) {
        tokenAccountID = id
    }

    // MARK: - Lifecycle

    /// Starts the pull loop. Call once when the first account is authenticated.
    func start(tokenAccountID: String) {
        self.tokenAccountID = tokenAccountID
        guard pullTask == nil else { return }
        scopeAlertPosted = false
        consecutiveFailures = 0
        pullTask = Task { await pullLoop() }
        Self.logger.info("PubSubService started with token account \(tokenAccountID)")
    }

    /// Stops the pull loop. Call on app termination or when all accounts sign out.
    func stop() {
        pullTask?.cancel()
        pullTask = nil
        debounceTask?.cancel()
        debounceTask = nil
        activeEngine = nil
        activeEmail = nil
        Self.logger.info("PubSubService stopped")
    }

    // MARK: - Pull Loop

    private func pullLoop() async {
        while !Task.isCancelled {
            do {
                let wasFailing = consecutiveFailures >= PubSubConfig.maxPullFailures
                let messages = try await pullMessages()

                // Reset failures on successful pull (even if no messages)
                consecutiveFailures = 0
                scopeAlertPosted = false

                // If we were failing and just recovered, re-enable Pub/Sub backup polling
                if wasFailing {
                    Self.logger.info("Pub/Sub pull recovered — switching to backup polling")
                    await activeEngine?.setPubSubActive(true)
                }

                if !messages.isEmpty {
                    var ackIds: [String] = []
                    for received in messages {
                        ackIds.append(received.ackId)
                        if let notification = decodeNotification(received.message) {
                            handleNotification(emailAddress: notification.emailAddress)
                        }
                    }
                    try? await acknowledge(ackIds: ackIds)
                }
            } catch is CancellationError {
                return
            } catch let error as PubSubError {
                consecutiveFailures += 1
                switch error {
                case .insufficientScope(let accountID):
                    Self.logger.error("Pub/Sub pull 403 — missing scope for \(accountID)")
                    if !scopeAlertPosted {
                        scopeAlertPosted = true
                        await MainActor.run {
                            NotificationCenter.default.post(
                                name: .pubSubScopesInsufficient,
                                object: nil,
                                userInfo: [GmailAPIClient.accountIDKey: accountID]
                            )
                        }
                    }
                    // Stop retrying rapidly on scope errors — wait 60s for re-auth
                    await activeEngine?.setPubSubActive(false)
                    try? await Task.sleep(for: .seconds(60))
                    continue

                case .permissionDenied(let accountID, let reason):
                    // IAM or API-disabled — re-auth won't fix this. Fall back to
                    // polling permanently for this session and don't pester the user.
                    Self.logger.error("Pub/Sub 403 (non-scope) for \(accountID): \(reason)")
                    await activeEngine?.setPubSubActive(false)
                    return  // Exit pull loop — polling covers sync

                case .httpError:
                    break  // Fall through to generic failure handling below
                }
                if consecutiveFailures >= PubSubConfig.maxPullFailures {
                    Self.logger.error("Pub/Sub pull failing — reverting to normal polling")
                    await activeEngine?.setPubSubActive(false)
                }
                try? await Task.sleep(for: .seconds(PubSubConfig.retryDelay))
            } catch {
                consecutiveFailures += 1
                Self.logger.warning("Pull failed (\(self.consecutiveFailures)x): \(error)")
                if consecutiveFailures >= PubSubConfig.maxPullFailures {
                    Self.logger.error("Pub/Sub pull failing — reverting to normal polling")
                    await activeEngine?.setPubSubActive(false)
                }
                try? await Task.sleep(for: .seconds(PubSubConfig.retryDelay))
            }
        }
    }

    // MARK: - REST API

    private func pullMessages() async throws -> [PubSubReceivedMessage] {
        guard let accountID = tokenAccountID else { return [] }

        let token = try await GmailAPIClient.shared.validPubSubToken(for: accountID)
        let url = URL(string: "\(PubSubConfig.baseURL)/\(PubSubConfig.subscriptionName):pull")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["maxMessages": 10])
        request.timeoutInterval = PubSubConfig.pullTimeout

        let (data, response) = try await GmailAPIClient.sharedSession.data(for: request)

        if let httpResponse = response as? HTTPURLResponse {
            if httpResponse.statusCode == 403 {
                let body = String(data: data, encoding: .utf8) ?? "<no body>"
                Self.logger.error("Pub/Sub 403 response: \(body)")
                throw Self.classify403(data: data, accountID: accountID)
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                throw PubSubError.httpError(statusCode: httpResponse.statusCode, data: data)
            }
        }

        let pullResponse = try JSONDecoder().decode(PubSubPullResponse.self, from: data)
        return pullResponse.receivedMessages ?? []
    }

    private func acknowledge(ackIds: [String]) async throws {
        guard let accountID = tokenAccountID, !ackIds.isEmpty else { return }

        let token = try await GmailAPIClient.shared.validPubSubToken(for: accountID)
        let url = URL(string: "\(PubSubConfig.baseURL)/\(PubSubConfig.subscriptionName):acknowledge")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["ackIds": ackIds])

        let (_, response) = try await GmailAPIClient.sharedSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            Self.logger.warning("Acknowledge failed for \(ackIds.count) messages")
            return
        }
    }

    // MARK: - Error Classification

    /// Parses a Google Cloud API 403 response to distinguish OAuth scope errors
    /// from IAM permission errors. Only scope errors are fixable via re-authorization.
    private nonisolated static func classify403(data: Data, accountID: String) -> PubSubError {
        // Google Cloud API errors include details[].reason:
        //   ACCESS_TOKEN_SCOPE_INSUFFICIENT → OAuth scope issue (re-auth can fix)
        //   IAM_PERMISSION_DENIED → IAM role missing (re-auth cannot fix)
        //   SERVICE_DISABLED → API not enabled (re-auth cannot fix)
        struct CloudError: Decodable {
            struct Detail: Decodable {
                let reason: String?
            }
            struct ErrorBody: Decodable {
                let message: String?
                let details: [Detail]?
            }
            let error: ErrorBody?
        }

        if let parsed = try? JSONDecoder().decode(CloudError.self, from: data) {
            let reason = parsed.error?.details?.first?.reason ?? ""
            if reason == "ACCESS_TOKEN_SCOPE_INSUFFICIENT" {
                return .insufficientScope(accountID: accountID)
            }
            let message = parsed.error?.message ?? reason
            return .permissionDenied(accountID: accountID, reason: message)
        }
        // Unparseable body — conservatively treat as permission denied (not scope)
        // to avoid a re-auth loop when the error can't be fixed by re-auth.
        return .permissionDenied(accountID: accountID, reason: "unknown 403")
    }

    // MARK: - Notification Handling

    private func decodeNotification(_ message: PubSubMessage) -> PubSubNotification? {
        guard let data = Data(base64Encoded: message.data) else {
            Self.logger.warning("Failed to base64-decode Pub/Sub message \(message.messageId)")
            return nil
        }
        do {
            return try JSONDecoder().decode(PubSubNotification.self, from: data)
        } catch {
            Self.logger.warning("Failed to decode Pub/Sub notification: \(error)")
            return nil
        }
    }

    /// Debounces notifications per email address — coalesces burst within 1s.
    private func handleNotification(emailAddress: String) {
        guard emailAddress == activeEmail, let engine = activeEngine else {
            Self.logger.debug("Notification for non-active account \(emailAddress) — discarding")
            return
        }

        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(for: .seconds(PubSubConfig.debounceInterval))
            guard !Task.isCancelled else { return }
            Self.logger.info("Triggering sync for \(emailAddress)")
            await engine.triggerIncrementalSync()
        }
    }
}
