import Foundation

public struct ProcessOutput: Sendable {
    public var status: Int32
    public var stdout: Data
    public var stderr: String
}

public enum ProcessRunnerError: Error, LocalizedError {
    case notExecutable(String)
    case timedOut(String)

    public var errorDescription: String? {
        switch self {
        case .notExecutable(let path): "\(path) is not available"
        case .timedOut(let command): "\(command) timed out"
        }
    }
}

/// Runs a command and kills it if it outlives `timeout`.
public enum ProcessRunner {
    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 60) throws -> ProcessOutput {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw ProcessRunnerError.notExecutable(executable)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()

        // Drain pipes while waiting so a chatty process cannot block on a full buffer.
        let stdout = OutputBuffer()
        let stderr = OutputBuffer()
        let readers = DispatchGroup()
        DispatchQueue.global().async(group: readers) { stdout.data = out.fileHandleForReading.readDataToEndOfFile() }
        DispatchQueue.global().async(group: readers) { stderr.data = err.fileHandleForReading.readDataToEndOfFile() }

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 5)
            throw ProcessRunnerError.timedOut(([executable] + arguments).joined(separator: " "))
        }
        readers.wait()
        return ProcessOutput(status: process.terminationStatus, stdout: stdout.data, stderr: String(decoding: stderr.data, as: UTF8.self))
    }
}

/// Written by exactly one reader; read only after `readers.wait()`, so no lock is needed.
private final class OutputBuffer: @unchecked Sendable {
    var data = Data()
}
