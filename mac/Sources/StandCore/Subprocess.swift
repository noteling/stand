import Foundation

/// Runs another program and waits for it from async code.
///
/// It waits through `terminationHandler`, never `waitUntilExit`. Starting a process on
/// one thread and calling `waitUntilExit` on another can miss the exit and wait for ever:
/// measured on 2026-11-11, 41 of 150 short-lived processes were never reported that way,
/// and none of 150 through the handler. It showed up as a rehearsal that hung after its
/// fourth `afplay`.
public enum Subprocess {
    public struct Result {
        public let status: Int32
        public let output: Data
        public let errors: Data
    }

    private final class Collected: @unchecked Sendable {
        var output = Data()
        var errors = Data()
    }

    /// `timeout` ends the program if it is still running after that many seconds.
    public static func run(_ path: String, _ arguments: [String] = [], environment: [String: String]? = nil,
                           directory: URL? = nil, timeout: Double? = nil) async throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let directory { process.currentDirectoryURL = directory }
        process.standardInput = FileHandle.nullDevice
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let collected = Collected()

        return try await withCheckedThrowingContinuation { (done: CheckedContinuation<Result, Error>) in
            let group = DispatchGroup()
            group.enter()
            process.terminationHandler = { _ in group.leave() }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                group.leave()
                done.resume(throwing: StandError("Could not start \(path): \(error.localizedDescription)"))
                return
            }
            // Both pipes are read while it runs, so a full pipe can never stall it.
            group.enter()
            DispatchQueue.global().async {
                collected.output = output.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            group.enter()
            DispatchQueue.global().async {
                collected.errors = errors.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            let limit = timeout.map { seconds in
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    if !Task.isCancelled, process.isRunning { process.terminate() }
                }
            }
            group.notify(queue: .global()) {
                limit?.cancel()
                done.resume(returning: Result(status: process.terminationStatus, output: collected.output, errors: collected.errors))
            }
        }
    }
}
