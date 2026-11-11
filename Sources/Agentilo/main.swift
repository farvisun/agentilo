import AgentiloCore
import AppKit
import SwiftUI

let cliArgs = Array(CommandLine.arguments.dropFirst())

if cliArgs.contains("--dump") {
    await DumpCommand.run()
    exit(0)
}

// Debug: `--preview-share-card <path> [provider]` writes a sample of the picture "Copy image" makes.
if let i = cliArgs.firstIndex(of: "--preview-share-card"), i + 1 < cliArgs.count {
    let now = Date()
    let snapshot = UsageSnapshot(windows: [
        UsageWindow(id: "session", kind: .session, title: "Session", usedPercent: 42,
                    resetsAt: now.addingTimeInterval(7_200), windowLength: 18_000),
        UsageWindow(id: "weekly", kind: .weekly, title: "Weekly", usedPercent: 81,
                    resetsAt: now.addingTimeInterval(172_800), windowLength: 604_800),
        UsageWindow(id: "extra", kind: .billing, title: "Extra usage", usedPercent: 12,
                    resetsAt: nil, windowLength: nil, detail: "$2.40 of $20.00"),
    ], plan: "Max", email: "hidden@example.com", fetchedAt: now)
    let provider = cliArgs.dropFirst(i + 2).first.flatMap(Provider.init(rawValue:)) ?? .claude
    let card = ShareCardRenderer.png(ShareCard(provider: provider, snapshot: snapshot, mode: .used, now: now))
    exit(card.flatMap { try? $0.write(to: URL(fileURLWithPath: cliArgs[i + 1])) } != nil ? 0 : 1)
}

// Debug: `--preview-account-page <path> [unified]` writes a sample expanded account page.
if let i = cliArgs.firstIndex(of: "--preview-account-page"), i + 1 < cliArgs.count {
    let png = await MainActor.run { () -> Data? in
        let now = Date()
        func w(_ id: String, _ kind: WindowKind, _ title: String, _ used: Double, _ reset: TimeInterval?,
               _ length: TimeInterval?, _ detail: String? = nil) -> UsageWindow {
            UsageWindow(id: id, kind: kind, title: title, usedPercent: used,
                        resetsAt: reset.map { now.addingTimeInterval($0) }, windowLength: length, detail: detail)
        }
        let a = UsageSnapshot(windows: [
            w("primary_window", .session, "Session", 40, 7_200, 18_000),
            w("secondary_window", .weekly, "Weekly", 64, 172_800, 604_800),
            w("spark_primary_window", .session, "Spark", 7, 7_200, 18_000),
            w("spark_secondary_window", .weekly, "Spark Weekly", 3, 172_800, 604_800),
            w("credit_limit", .billing, "Credit limit", 25, 900_000, nil, "150 of 600 credits"),
            w("credits", .balance, "Credits", 0, nil, nil, "812 credits · ≈ $32.48"),
        ], plan: "Pro", fetchedAt: now.addingTimeInterval(-90), resetGrants: ResetGrants(available: 2))
        let b = UsageSnapshot(windows: [
            w("primary_window", .session, "Session", 80, 9_000, 18_000),
            w("secondary_window", .weekly, "Weekly", 30, 172_800, 604_800),
        ], plan: "Plus", fetchedAt: now.addingTimeInterval(-60))
        let unified = cliArgs.dropFirst(i + 2).first == "unified"
        var status = AccountStatus()
        status.snapshot = unified ? UnifiedAccounts.merge([a, b], now: now) : a
        let page = AccountPage(
            account: Account(provider: .codex, homePath: "", label: unified ? "2 accounts" : "me@example.com"),
            status: status, stats: TokenStats(), mode: .used, now: now,
            nextCheck: now.addingTimeInterval(80),
            breakdown: unified ? [("me@work", a), ("me@home", b)] : []
        )
        .frame(width: 520, height: 230)
        .padding(18)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: page)
        renderer.scale = 2
        guard let image = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
    exit(png.flatMap { try? $0.write(to: URL(fileURLWithPath: cliArgs[i + 1])) } != nil ? 0 : 1)
}

// `agentilo <command>`: command-line use of the same binary, through the symlink
// Settings installs. Never starts the UI.
switch cliArgs.first {
case "limits":
    exit(await LimitsCommand.run(Array(cliArgs.dropFirst())))
case "hook":
    exit(await HookCommand.run(Array(cliArgs.dropFirst())))
case "quiet":
    exit(await QuietCommand.run(Array(cliArgs.dropFirst())))
case "awake":
    exit(await AwakeCommand.run(Array(cliArgs.dropFirst())))
case "help", "-h", "--help":
    print("""
    usage: agentilo <command>

      limits    print plan limits (see `agentilo limits --help`)
      quiet     silence alerts: on, off, 1h, status (see `agentilo quiet --help`)
      awake     keep the Mac awake while agents work: on, off, lid on, status

    Run without a command to start the notch app.
    """)
    exit(0)
default:
    break
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
