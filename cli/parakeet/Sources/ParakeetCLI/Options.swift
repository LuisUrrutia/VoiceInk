import FluidAudio
import Foundation

enum CLIError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}

enum OutputFormat: String { case txt, json, srt }

struct Options {
    static let version = "1.0.0"
    static let usage = """
    Usage: voiceink-cli [options] [--] AUDIO...
      -f, --format txt|json|srt        Output format (default: txt)
      -o, --output PATH               File, or directory for batches
          --skip-existing             Skip existing regular output files
          --model v2|v3               Installed Parakeet model (default: v3)
          --model-directory PATH      Exact directory of compiled model files
          --lang auto|CODE            Decoder script hint (v2: auto or en)
          --namespace production|development|local (default: production)
          --preferences PATH          Read an explicit preferences plist snapshot
          --dictionary PATH           Read a VoiceInk Dictionary JSON export
          --no-vad --no-format --keep-fillers --no-replacements
      -q, --quiet                     Suppress progress (errors remain on stderr)
      -h, --help                      Show usage
          --version                   Show version
    Batches require --output DIR. Models are never downloaded. No app store is opened.
    Exit codes: 0 success, 1 processing failure, 2 invalid invocation.
    """
    var inputs: [URL] = []
    var format: OutputFormat = .txt
    var output: URL?
    var skipExisting = false
    var model = "v3"
    var modelDirectory: URL?
    var language: String?
    var namespace: AppNamespace = .production
    var preferences: URL?
    var dictionary: URL?
    var noVAD = false
    var noFormat = false
    var keepFillers = false
    var noReplacements = false
    var quiet = false
    var help = false
    var showVersion = false

    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var index = 0
        var positional = false
        func value(_ flag: String) throws -> String {
            index += 1
            guard index < arguments.count else { throw CLIError.message("Missing value for \(flag)") }
            return arguments[index]
        }
        while index < arguments.count {
            let argument = arguments[index]
            if positional {
                options.inputs.append(URL(fileURLWithPath: argument))
            } else {
                switch argument {
                case "--": positional = true
                case "-h", "--help": options.help = true
                case "--version": options.showVersion = true
                case "-q", "--quiet": options.quiet = true
                case "--skip-existing": options.skipExisting = true
                case "--no-vad": options.noVAD = true
                case "--no-format": options.noFormat = true
                case "--keep-fillers": options.keepFillers = true
                case "--no-replacements": options.noReplacements = true
                case "-f", "--format":
                    let raw = try value(argument)
                    guard let format = OutputFormat(rawValue: raw) else { throw CLIError.message("Unsupported format: \(raw)") }
                    options.format = format
                case "-o", "--output": options.output = URL(fileURLWithPath: try value(argument))
                case "--model": options.model = try value(argument)
                case "--model-directory": options.modelDirectory = URL(fileURLWithPath: try value(argument))
                case "--lang": options.language = try value(argument)
                case "--namespace":
                    let raw = try value(argument)
                    guard let namespace = AppNamespace(rawValue: raw) else { throw CLIError.message("Unsupported namespace: \(raw)") }
                    options.namespace = namespace
                case "--preferences": options.preferences = URL(fileURLWithPath: try value(argument))
                case "--dictionary": options.dictionary = URL(fileURLWithPath: try value(argument))
                default:
                    guard !argument.hasPrefix("-") else { throw CLIError.message("Unknown option: \(argument). Use -- before dash-leading files.") }
                    options.inputs.append(URL(fileURLWithPath: argument))
                }
            }
            index += 1
        }
        if options.help || options.showVersion { return options }
        guard !options.inputs.isEmpty else { throw CLIError.message("Provide at least one audio file") }
        guard ["v2", "v3"].contains(options.model) else { throw CLIError.message("Model must be v2 or v3") }
        if let language = options.language, language != "auto" {
            guard Language(rawValue: language) != nil else {
                throw CLIError.message("Unsupported language. Use auto or \(Language.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            guard options.model != "v2" || language == "en" else { throw CLIError.message("Parakeet v2 supports only English") }
        }
        guard options.inputs.count == 1 || options.output != nil else { throw CLIError.message("Batches require --output DIR") }
        guard !options.skipExisting || options.output != nil else { throw CLIError.message("--skip-existing requires --output") }
        return options
    }
}
