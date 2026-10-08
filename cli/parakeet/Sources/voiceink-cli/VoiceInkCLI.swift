import Foundation
import ParakeetCLI

@main
struct VoiceInkCLI {
    static func main() async {
        let code = await CLIApplication.run(arguments: Array(CommandLine.arguments.dropFirst()),
                                            stdout: { FileHandle.standardOutput.write($0) },
                                            stderr: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) })
        exit(code)
    }
}
