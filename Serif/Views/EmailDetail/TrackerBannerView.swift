import SwiftUI

struct TrackerBannerView: View {
    let trackerCount: Int
    let onAllow: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "eye.slash.fill")
                .font(.system(size: 13))
                .foregroundStyle(.tint)

            Text("\(trackerCount) tracker\(trackerCount > 1 ? "s" : "") blocked")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)

            Spacer()

            Button {
                onAllow()
            } label: {
                Text("Load blocked content")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tint)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.12))
                    .cornerRadius(5)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .cornerRadius(8)
    }
}
