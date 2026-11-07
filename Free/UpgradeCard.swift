import AppKit
import SwiftUI

/// The free edition's one nudge: a quiet card above Settings that names what Taki Pro adds.
struct UpgradeCard: View {
    var body: some View {
        Button { if let url = URL(string: Edition.upgradeURL) { NSWorkspace.shared.open(url) } } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Taki Pro").font(.system(size: 14, weight: .semibold))
                Text("Chat with Claude, workspaces, the menu bar, unlimited tabs and more.")
                    .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Learn more").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.link).padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .tileSurface(radius: 12)
        }
        .buttonStyle(.plain)
        .help("Opens the Taki Pro page")
    }
}
