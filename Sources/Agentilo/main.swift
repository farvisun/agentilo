import AgentiloCore
import AppKit

let cliArgs = Array(CommandLine.arguments.dropFirst())

if cliArgs.contains("--dump") {
    await DumpCommand.run()
    exit(0)
}

// Debug: `--preview-share-card <path>` writes a sample of the picture "Copy image" makes.
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
    let card = ShareCardRenderer.png(ShareCard(provider: .claude, snapshot: snapshot, mode: .used, now: now))
    exit(card.flatMap { try? $0.write(to: URL(fileURLWithPath: cliArgs[i + 1])) } != nil ? 0 : 1)
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
