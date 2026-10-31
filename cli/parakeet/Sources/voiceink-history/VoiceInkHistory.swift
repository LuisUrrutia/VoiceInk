import Foundation
import HistoryAccessCLI

@main
struct VoiceInkHistory {
    static func main() {
        let code = HistoryCLIApplication.run(
            arguments: Array(CommandLine.arguments.dropFirst()),
            stdout: { FileHandle.standardOutput.write($0) },
            stderr: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) })
        exit(code)
    }
}
