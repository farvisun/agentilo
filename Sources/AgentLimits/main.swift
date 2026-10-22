import AgentLimitsCore
import AppKit

let cliArgs = Array(CommandLine.arguments.dropFirst())

if cliArgs.contains("--dump") {
    await DumpCommand.run()
    exit(0)
}

// `agentlimits <command>`: command-line use of the same binary, through the symlink
// Settings installs. Never starts the UI.
switch cliArgs.first {
case "limits":
    exit(await LimitsCommand.run(Array(cliArgs.dropFirst())))
case "help", "-h", "--help":
    print("""
    usage: agentlimits <command>

      limits    print plan limits (see `agentlimits limits --help`)

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
