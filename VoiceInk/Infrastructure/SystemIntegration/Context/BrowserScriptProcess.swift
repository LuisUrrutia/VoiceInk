import Darwin
import Foundation

final class BrowserScriptProcess: @unchecked Sendable {
    private let queue = DispatchQueue(label: "voiceink.browser-script", qos: .userInitiated)
    private let process = Process()
    private let pipe = Pipe()
    private var reader: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private var continuation: CheckedContinuation<Data, Error>?
    private var output = Data()
    private var exited = false
    private var drained = false
    private var cancelled = false
    private var failure: Error?
    private var finished = false
    private var readerInstalled = false
    private let outputLimit = 1_048_576

    init(executableURL: URL = URL(fileURLWithPath: "/usr/bin/osascript"), arguments: [String]) {
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
    }

    func run(timeout: TimeInterval = 1.5) async throws -> Data {
        let data = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async { self.start(continuation, timeout: timeout) }
            }
        } onCancel: {
            self.queue.async {
                self.cancelled = true
                self.stop(CancellationError())
            }
        }
        try Task.checkCancellation()
        return data
    }

    private func start(_ continuation: CheckedContinuation<Data, Error>, timeout: TimeInterval) {
        self.continuation = continuation
        guard !cancelled else { finish(.failure(CancellationError())); return }

        let handle = pipe.fileHandleForReading
        let fd = handle.fileDescriptor
        guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) != -1 else {
            finish(.failure(BrowserURLError.executionFailed))
            return
        }
        let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        reader.setEventHandler { [weak self] in self?.readOutput() }
        reader.setCancelHandler { try? handle.close() }
        self.reader = reader
        readerInstalled = true
        reader.resume()

        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                self.exited = true
                self.completeIfReady()
            }
        }
        do {
            try process.run()
            try? pipe.fileHandleForWriting.close()
            schedule(after: timeout) { self.stop(BrowserURLError.executionTimedOut) }
        } catch {
            finish(.failure(BrowserURLError.executionFailed))
        }
    }

    private func readOutput() {
        guard !finished, failure == nil else { return }
        var buffer = [UInt8](repeating: 0, count: 16_384)
        // Bound each drain so continuous output cannot starve cancellation or the deadline.
        for _ in 0..<4 {
            let count = Darwin.read(pipe.fileHandleForReading.fileDescriptor, &buffer, buffer.count)
            if count > 0 {
                guard output.count + count <= outputLimit else {
                    stop(BrowserURLError.executionFailed)
                    return
                }
                output.append(contentsOf: buffer.prefix(count))
            } else if count == 0 {
                drained = true
                reader?.cancel()
                reader = nil
                completeIfReady()
                return
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else {
                stop(BrowserURLError.executionFailed)
                return
            }
        }
    }

    private func completeIfReady() {
        guard !finished else { return }
        if exited, let failure {
            finish(.failure(failure))
        } else if exited && drained {
            finish(process.terminationStatus == 0
                ? .success(output) : .failure(BrowserURLError.executionFailed))
        }
    }

    private func stop(_ error: Error) {
        guard !finished, continuation != nil, failure == nil else { return }
        failure = error
        reader?.cancel()
        reader = nil
        guard process.isRunning else { finish(.failure(error)); return }
        process.terminate()
        schedule(after: 0.2) {
            if self.process.isRunning { kill(self.process.processIdentifier, SIGKILL) }
            self.schedule(after: 0.3) { self.finish(.failure(error)) }
        }
    }

    private func schedule(after seconds: TimeInterval, action: @escaping () -> Void) {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler(handler: action)
        self.timer = timer
        timer.resume()
    }

    private func finish(_ result: Result<Data, Error>) {
        guard !finished else { return }
        finished = true
        timer?.cancel()
        timer = nil
        reader?.cancel()
        reader = nil
        process.terminationHandler = nil
        try? pipe.fileHandleForWriting.close()
        if !readerInstalled { try? pipe.fileHandleForReading.close() }
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }
}
