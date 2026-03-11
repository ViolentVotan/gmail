# AI Label Suggestions Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Suggest up to 3 labels (existing or new) for an email using Apple Intelligence, displayed as clickable chips below the LabelEditorView.

**Architecture:** New `LabelSuggestionService` (singleton, same pattern as `QuickReplyService`) uses FoundationModels to generate suggestions. Results cached in-memory per `gmailMessageID`. Feature gated by macOS 26+ and `@AppStorage("aiLabelSuggestions")` toggle.

**Tech Stack:** Swift, SwiftUI, FoundationModels (macOS 26+)

---

### Task 1: Create LabelSuggestionService

**Files:**
- Create: `Serif/Services/LabelSuggestionService.swift`

**Step 1: Create the service file**

```swift
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

struct LabelSuggestion: Equatable {
    let name: String
    let isNew: Bool
}

@MainActor
final class LabelSuggestionService {
    static let shared = LabelSuggestionService()
    private var cache: [String: [LabelSuggestion]] = [:]
    private init() {}

    func cachedSuggestions(for email: Email) -> [LabelSuggestion]? {
        guard let key = cacheKey(for: email) else { return nil }
        return cache[key]
    }

    func generateSuggestions(for email: Email, existingLabels: [GmailLabel]) async -> [LabelSuggestion] {
        if let key = cacheKey(for: email), let cached = cache[key] { return cached }

        if #available(macOS 26.0, *) {
            #if canImport(FoundationModels)
            return await generateWithFoundationModels(email: email, existingLabels: existingLabels)
            #else
            return []
            #endif
        } else {
            return []
        }
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private func generateWithFoundationModels(email: Email, existingLabels: [GmailLabel]) async -> [LabelSuggestion] {
        do {
            let labelNames = existingLabels
                .filter { !$0.isSystemLabel }
                .map(\.displayName)
                .joined(separator: ", ")

            let instructions = Instructions("""
            You are an email assistant inside a macOS email client. \
            The user wants label suggestions for the current email. \
            Rules:
            - Suggest 1 to 3 labels that best categorize this email.
            - Prefer existing labels when they fit. Only suggest new labels if nothing existing matches.
            - Return JSON array only, no extra text: [{"name": "Label", "isNew": false}]
            - isNew = true only if the label is NOT in the existing labels list.
            - Label names should be short (1-3 words), capitalized, in English.
            - Do not suggest labels that are already applied to the email.
            """)
            let session = LanguageModelSession(instructions: instructions)

            let body = String(email.preview.prefix(200))
            let prompt = """
            Existing labels: \(labelNames.isEmpty ? "none" : labelNames)

            Subject: \(email.subject)
            Preview: \(body)
            From: \(email.sender.name) <\(email.sender.email)>
            """

            let response = try await session.respond(to: prompt)
            let suggestions = parseSuggestions(from: response.content, existingLabels: existingLabels)

            if let key = cacheKey(for: email) {
                cache[key] = suggestions
            }
            return suggestions
        } catch {
            return []
        }
    }
    #endif

    private func parseSuggestions(from text: String, existingLabels: [GmailLabel]) -> [LabelSuggestion] {
        // Extract JSON array from response (may contain markdown fences)
        var jsonString = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = jsonString.range(of: "["), let end = jsonString.range(of: "]", options: .backwards) {
            jsonString = String(jsonString[start.lowerBound...end.upperBound])
        }

        guard let data = jsonString.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }

        let existingNames = Set(existingLabels.filter { !$0.isSystemLabel }.map { $0.displayName.lowercased() })

        return raw.prefix(3).compactMap { dict in
            guard let name = dict["name"] as? String, !name.isEmpty else { return nil }
            let isNew = !existingNames.contains(name.lowercased())
            return LabelSuggestion(name: name, isNew: isNew)
        }
    }

    private func cacheKey(for email: Email) -> String? {
        email.gmailMessageID ?? email.id.uuidString
    }
}
```

**Step 2: Build to verify**

Run: `xcodebuild -project Serif.xcodeproj -scheme Serif -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Serif/Services/LabelSuggestionService.swift
git commit -m "feat: add LabelSuggestionService with Apple Intelligence"
```

---

### Task 2: Add Apple Intelligence settings card

**Files:**
- Modify: `Serif/Views/Common/SettingsCardsView.swift` (add card before DeveloperSettingsCard, line ~322)
- Modify: `Serif/Views/Common/SlidePanelsOverlay.swift` (add card at line 52, before StorageSettingsCard)

**Step 1: Add the card to SettingsCardsView.swift**

Insert before `// MARK: - Developer Settings` (line 323):

```swift
// MARK: - Apple Intelligence Settings

struct AppleIntelligenceSettingsCard: View {
    @AppStorage("aiLabelSuggestions") private var labelSuggestions = true
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Apple Intelligence")
                .font(.serifTitle)
                .foregroundColor(theme.textPrimary)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Label suggestions")
                        .font(.serifCaption)
                        .foregroundColor(theme.textSecondary)
                    Text("Suggest labels for emails using on-device AI")
                        .font(.serifSmall)
                        .foregroundColor(theme.textTertiary)
                }
                Spacer()
                Toggle("", isOn: $labelSuggestions)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}
```

**Step 2: Add to SlidePanelsOverlay.swift**

At line 52 (before `StorageSettingsCard`), add:

```swift
AppleIntelligenceSettingsCard()
```

**Step 3: Build to verify**

Run: `xcodebuild -project Serif.xcodeproj -scheme Serif -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 4: Commit**

```bash
git add Serif/Views/Common/SettingsCardsView.swift Serif/Views/Common/SlidePanelsOverlay.swift
git commit -m "feat: add Apple Intelligence settings card with label suggestions toggle"
```

---

### Task 3: Display suggestion chips in EmailDetailView

**Files:**
- Modify: `Serif/Views/EmailDetail/EmailDetailView.swift` (lines 187-197, after LabelEditorView)

**Step 1: Add state and suggestion loading**

Add to EmailDetailView's existing `@State` properties (around line 37):

```swift
@State private var labelSuggestions: [LabelSuggestion] = []
@AppStorage("aiLabelSuggestions") private var aiLabelSuggestionsEnabled = true
```

**Step 2: Add suggestion chips view below LabelEditorView**

After the LabelEditorView block (line 197, after `.zIndex(1)`), insert:

```swift
if !labelSuggestions.isEmpty {
    HStack(spacing: 6) {
        ForEach(labelSuggestions, id: \.name) { suggestion in
            Button {
                applyLabelSuggestion(suggestion)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: suggestion.isNew ? "plus.circle" : "plus")
                        .font(.system(size: 9, weight: .semibold))
                    Text(suggestion.name)
                        .font(.system(size: 11, weight: .medium))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(theme.accentPrimary.opacity(0.1))
                .foregroundColor(theme.accentPrimary)
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(theme.accentPrimary.opacity(0.3), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
    }
    .padding(.horizontal, 24)
    .padding(.bottom, 12)
    .animation(.easeOut(duration: 0.25), value: labelSuggestions.map(\.name))
}
```

**Step 3: Add suggestion loading logic**

Add a `.task(id:)` modifier on the ScrollView (or alongside existing lifecycle modifiers) that triggers when the email changes:

```swift
.task(id: email.id) {
    labelSuggestions = []
    guard aiLabelSuggestionsEnabled else { return }
    let suggestions = await LabelSuggestionService.shared.generateSuggestions(
        for: email,
        existingLabels: allLabels
    )
    withAnimation { labelSuggestions = suggestions }
}
```

**Step 4: Add the apply helper method**

Add to EmailDetailView:

```swift
private func applyLabelSuggestion(_ suggestion: LabelSuggestion) {
    withAnimation { labelSuggestions.removeAll { $0.name == suggestion.name } }
    if suggestion.isNew {
        onCreateAndAddLabel?(suggestion.name) { _ in }
    } else if let label = allLabels.first(where: { $0.displayName == suggestion.name }) {
        var newIDs = currentLabelIDs
        newIDs.append(label.id)
        detailVM.updateLabelIDs(newIDs)
        onAddLabel?(label.id)
    }
}
```

**Step 5: Build to verify**

Run: `xcodebuild -project Serif.xcodeproj -scheme Serif -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 6: Commit**

```bash
git add Serif/Views/EmailDetail/EmailDetailView.swift
git commit -m "feat: display AI label suggestion chips in email detail view"
```

---

### Task 4: End-to-end verification

**Step 1: Build and launch**

```bash
xcodebuild -project Serif.xcodeproj -scheme Serif -configuration Debug build
open /Users/marshalino16/Library/Developer/Xcode/DerivedData/Serif-fsylqdbmresrapbjzjfgliztotka/Build/Products/Debug/Serif.app
```

**Step 2: Verify**

1. Open an email → label suggestion chips should appear below labels (macOS 26+ only)
2. Click a suggestion → label is added, chip disappears
3. Open Settings → "Apple Intelligence" card visible with "Label suggestions" toggle
4. Disable toggle → reselect email → no suggestions appear
5. Select same email again → suggestions load from cache instantly

**Step 3: Final commit if any adjustments needed**
