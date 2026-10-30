import Foundation
import ParakeetCLI

@main
struct VocabularyEvaluationCLI {
    static func main() async {
        let code = await VocabularyEvaluationApplication.run(
            arguments: Array(CommandLine.arguments.dropFirst()),
            stdout: { print($0) },
            stderr: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
        )
        exit(code)
    }
}
