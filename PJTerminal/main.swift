import AppKit
import GhosttyKit

// Initialize Ghostty global state before starting the app
if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
    NSLog("ghostty_init failed")
    exit(1)
}

PJTerminalApp.main()
