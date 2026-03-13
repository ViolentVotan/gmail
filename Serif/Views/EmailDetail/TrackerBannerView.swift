import SwiftUI

struct TrackerBannerView: View {
    let trackerCount: Int
    let trackers: [TrackerInfo]
    let onAllow: () -> Void

    @State private var showDetails = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "eye.slash.fill")
                    .font(Typography.caption)
                    .foregroundStyle(.tint)

                Text("\(trackerCount) tracker\(trackerCount > 1 ? "s" : "") blocked")
                    .font(Typography.caption)
                    .foregroundStyle(.primary)

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showDetails.toggle()
                    }
                } label: {
                    Text(showDetails ? "Hide details" : "Show details")
                        .font(Typography.captionSmallMedium)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    onAllow()
                } label: {
                    Text("Load blocked content")
                        .font(Typography.captionSmallMedium)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .glassOrMaterial(in: .capsule, interactive: true)
                }
                .buttonStyle(.plain)
            }

            if showDetails {
                Divider()
                    .padding(.top, 8)

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(groupedTrackers, id: \.name) { group in
                        HStack(spacing: 6) {
                            Image(systemName: group.icon)
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                                .frame(width: 12)
                            Text(group.name)
                                .font(Typography.captionSmallMedium)
                                .foregroundStyle(.primary)
                            if group.count > 1 {
                                Text("×\(group.count)")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Text(group.kindLabel)
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.top, 8)
                .transition(.opacity)
            }
        }
        .compactCardStyle()
        .accessibilityLabel("Blocked \(trackerCount) trackers")
    }

    // MARK: - Grouped trackers

    private struct TrackerGroup: Hashable {
        let name: String
        let kind: TrackerKind
        let count: Int
        var icon: String {
            switch kind {
            case .pixel:        return "circle.fill"
            case .knownTracker: return "antenna.radiowaves.left.and.right"
            case .cssTracker:   return "paintbrush"
            case .trackingLink: return "link"
            }
        }
        var kindLabel: String {
            switch kind {
            case .pixel:        return "Pixel"
            case .knownTracker: return "Tracker"
            case .cssTracker:   return "CSS"
            case .trackingLink: return "Link"
            }
        }
    }

    private var groupedTrackers: [TrackerGroup] {
        var counts: [String: (kind: TrackerKind, count: Int)] = [:]
        for t in trackers {
            let name = t.serviceName ?? t.source
            if let existing = counts[name] {
                counts[name] = (existing.kind, existing.count + 1)
            } else {
                counts[name] = (t.kind, 1)
            }
        }
        return counts.map { TrackerGroup(name: $0.key, kind: $0.value.kind, count: $0.value.count) }
            .sorted { $0.count > $1.count }
    }
}
