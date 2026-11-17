import AppKit
import StandCore

// One binary, several uses: `--probe <mode>` checks one piece from the command line
// (`--probe panel` among them, which needs the app's own run loop and so starts here),
// `--rehearse [script]` runs the scripted audience, `--render-panel <folder>` draws the
// window to PNG files, and with no arguments it is the app.
let arguments = Array(CommandLine.arguments.dropFirst())

// Print each line as it is written, even into a pipe or a file. A command-line run that
// hangs or is stopped would otherwise leave nothing to read.
setvbuf(stdout, nil, _IOLBF, 0)

// Writing to a program that has gone away must fail as an error, not end this process.
// The brain is such a program: one that is kept open and written to.
signal(SIGPIPE, SIG_IGN)

/// A command-line run that puts up a window (the screen a talk's pages are shown on) needs
/// the app's own run loop on the main thread, as the app has. Every other run parks the
/// main thread and never touches the window server.
let needsWindows = arguments.contains("--screen") || arguments.contains("--show-screen") || arguments.contains("--in-chrome")
    || (arguments.count >= 2 && arguments[0] == "--probe" && (arguments[1] == "screen" || arguments[1] == "page"))
    || arguments.contains("--add-page") || arguments.contains("--read-pages") || arguments.contains("--as-the-panel-adds")
func keepMainThread() -> Never {
    if needsWindows {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            app.run()
        }
        exit(0)
    }
    dispatchMain()
}

if arguments.count >= 2, arguments[0] == "--probe", arguments[1] == "panel" {
    // The real window, driven with nobody at the keyboard. It is on screen for about three seconds.
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            let failures = await delegate.selfTest()
            for failure in failures { print("FAIL  \(failure)") }
            if failures.isEmpty { print("PASS  the window resizes in place, and the note field takes typing and Return") }
            exit(failures.isEmpty ? 0 : 1)
        }
        app.run()
    }
} else if let flag = arguments.firstIndex(of: "--probe") {
    let mode = arguments.indices.contains(flag + 1) ? arguments[flag + 1] : ""
    Task {
        do {
            try await Probe.run(mode: mode, arguments: arguments)
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }
    keepMainThread()
} else if let flag = arguments.firstIndex(of: "--rehearse") {
    let script = arguments.indices.contains(flag + 1) && !arguments[flag + 1].hasPrefix("--") ? arguments[flag + 1] : nil
    Task {
        do {
            try await Rehearsal.run(scriptPath: script, arguments: arguments)
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }
    keepMainThread()
} else if let flag = arguments.firstIndex(of: "--render-panel"), arguments.indices.contains(flag + 1) {
    MainActor.assumeIsolated {
        do {
            try RenderPanel.run(folder: arguments[flag + 1])
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }
} else {
    // Top-level code runs on the main thread; say so, since the app's types are main-actor only.
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = AppDelegate() // the app only holds it weakly; this keeps it alive for the run
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
