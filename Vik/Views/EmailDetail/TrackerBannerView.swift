import SwiftUI

struct TrackerBannerView: View {
    let trackerCount: Int
    let groupedTrackers: [TrackerGroup]
    let onAllow: () -> Void

    @State private var showDetails = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "eye.slash.fill")
                    .font(Typography.caption)
                    .foregroundStyle(.tint)

                Text("\(trackerCount) tracker\(trackerCount > 1 ? "s" : "") blocked")
                    .font(Typography.caption)
                    .foregroundStyle(.primary)

                Button {
                    withAnimation(reduceMotion ? nil : VikAnimation.springDefault) {
                        showDetails.toggle()
                    }
                } label: {
                    Text(showDetails ? "Hide details" : "Show details")
                        .font(Typography.captionSmallMedium)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showDetails ? "Hide tracker details" : "Show tracker details")
                .help(showDetails ? "Hide tracker details" : "Show tracker details")

                Spacer()

                Button {
                    onAllow()
                } label: {
                    Text("Load blocked content")
                        .font(Typography.captionSmallMedium)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Spacing.sm)
                        .padding(.vertical, Spacing.xs)
                        .glassOrMaterial(in: .capsule, interactive: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Load blocked content")
                .help("Load blocked content")
            }

            if showDetails {
                Divider()
                    .padding(.top, Spacing.sm)

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    ForEach(groupedTrackers) { group in
                        HStack(spacing: Spacing.xsm) {
                            Image(systemName: group.icon)
                                .font(Typography.trackerLabel)
                                .foregroundStyle(.tertiary)
                                .frame(width: 12)
                            Text(group.name)
                                .font(Typography.captionSmallMedium)
                                .foregroundStyle(.primary)
                            if group.count > 1 {
                                Text("×\(group.count)")
                                    .font(Typography.trackerLabelMedium)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Text(group.kindLabel)
                                .font(Typography.trackerLabel)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.top, Spacing.sm)
                .transition(.opacity)
            }
        }
        .compactCardStyle()
        .accessibilityLabel("Blocked \(trackerCount) trackers")
    }

    // MARK: - Grouped trackers

    struct TrackerGroup: Hashable, Identifiable {
        let name: String
        let kind: TrackerKind
        let count: Int
        var id: String { "\(name)-\(kind.rawValue)" }
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

        static func group(from trackers: [TrackerInfo]) -> [TrackerGroup] {
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

}
