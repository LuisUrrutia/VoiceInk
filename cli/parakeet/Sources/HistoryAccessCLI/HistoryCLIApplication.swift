import Foundation
import TranscriptionText

public enum HistoryCLIApplication {
    public static func run(
        arguments: [String],
        stdout: (Data) -> Void,
        stderr: (String) -> Void,
        readLine: () -> String? = { Swift.readLine(strippingNewline: true) },
        now: Date = Date(),
        timeZone: TimeZone = .current,
        transport: @escaping (AppNamespace) throws -> HistoryTransport = { try HistorySocketClient(namespace: $0) }
    ) -> Int32 {
        let invocation: HistoryInvocation
        do {
            invocation = try HistoryCommandLine.parse(arguments, now: now)
        } catch {
            stderr("\(error)\n\n\(HistoryCommandLine.usage)")
            return 2
        }
        switch invocation {
        case .help:
            stdout(Data((HistoryCommandLine.usage + "\n").utf8))
            return 0
        case .version:
            stdout(Data("voiceink-history \(HistoryCommandLine.version)\n".utf8))
            return 0
        case .mcp(let namespace):
            let server = HistoryMCPServer(now: { Date() }, transport: { try transport(namespace) })
            while let line = readLine() {
                if let reply = server.handle(line) { stdout(reply + Data("\n".utf8)) }
            }
            return 0
        case .request(let request, let json, let namespace):
            let response: HistoryAccessResponse
            do {
                response = try transport(namespace).send(request)
            } catch HistoryClientError.unavailable(let message) {
                stderr(message)
                return 3
            } catch HistoryClientError.protocolFailure(let message) {
                stderr(message)
                return 1
            } catch {
                stderr("Could not read History.")
                return 1
            }
            if let failure = response.error {
                stderr("\(failure.code.rawValue): \(failure.message)")
                return 1
            }
            if json {
                stdout(HistoryOutput.json(response) + Data("\n".utf8))
            } else {
                stdout(Data(HistoryOutput.text(response, timeZone: timeZone).utf8))
            }
            return 0
        }
    }
}

enum HistoryOutput {
    static func json(_ value: some Encodable) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)) ?? Data("{}".utf8)
    }

    static func text(_ response: HistoryAccessResponse, timeZone: TimeZone) -> String {
        if let entry = response.entry {
            var lines = [
                "ID: \(entry.id)",
                "Time: \(localTime(entry.timestamp, timeZone: timeZone))",
                "Mode: \(entry.mode ?? "-")",
                "Transcription model: \(entry.transcriptionModel ?? "-")",
                "Enhancement model: \(entry.enhancementModel ?? "-")",
                "Prompt: \(entry.prompt ?? "-")",
                "Duration: \(seconds(entry.durationMilliseconds))",
                "",
                "Original text:",
                entry.originalText,
            ]
            if let enhanced = entry.enhancedText {
                lines += ["", "Enhanced text:", enhanced]
            }
            return lines.joined(separator: "\n") + "\n"
        }
        let entries = response.entries ?? []
        guard !entries.isEmpty else { return "No matching History entries.\n" }
        var output = entries.map { entry in
            let details = [entry.mode, entry.transcriptionModel, seconds(entry.durationMilliseconds)]
                .compactMap { $0 }.joined(separator: " · ")
            return "\(localTime(entry.timestamp, timeZone: timeZone))  \(details)\n\(entry.id)\n"
                + "\(entry.enhancedText ?? entry.originalText)\n"
        }.joined(separator: "\n")
        if let cursor = response.nextCursor {
            output += "\nMore entries: --cursor \(cursor)\n"
        }
        return output
    }

    private static func localTime(_ timestamp: String, timeZone: TimeZone) -> String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = parser.date(from: timestamp) else { return timestamp }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    private static func seconds(_ milliseconds: Int) -> String {
        String(format: "%.1f s", Double(milliseconds) / 1000)
    }
}
