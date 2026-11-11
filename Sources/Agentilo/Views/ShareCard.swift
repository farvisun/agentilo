import AgentiloCore
import AppKit
import SwiftUI

/// The picture "Copy image" puts on the clipboard. Never shows the email or the account label.
struct ShareCard: View {
    var provider: Provider
    var snapshot: UsageSnapshot
    var mode: UsageDisplay
    var now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ProviderIcon(provider: provider, size: 22)
                Text(provider.displayName)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                if let plan = snapshot.plan {
                    Text(plan)
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.white.opacity(0.1)))
                        .foregroundStyle(Palette.secondary)
                }
                Spacer()
                Text("Agentilo")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(Palette.tertiary)
            }
            VStack(spacing: 9) {
                ForEach(snapshot.windows.filter { $0.kind != .balance }) { w in
                    WindowRow(window: w, mode: mode, estimated: snapshot.source == .estimated, now: now)
                }
            }
            let balances = snapshot.windows.filter { $0.kind == .balance }
            if !balances.isEmpty {
                MoreWindowsLine(windows: balances, mode: mode, now: now)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .frame(width: 460)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black))
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }
}

@MainActor
enum ShareCardRenderer {
    static func png(_ card: ShareCard) -> Data? {
        let renderer = ImageRenderer(content: card)
        renderer.scale = 2
        guard let image = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// Returns false when the picture could not be drawn.
    static func copy(_ card: ShareCard) -> Bool {
        guard let png = png(card) else { return false }
        let board = NSPasteboard.general
        board.clearContents()
        board.setData(png, forType: .png)
        // Some apps only paste TIFF.
        if let tiff = NSImage(data: png)?.tiffRepresentation { board.setData(tiff, forType: .tiff) }
        return true
    }
}
