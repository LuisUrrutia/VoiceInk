import Foundation

enum LocalCLITemplate: String, CaseIterable, Identifiable {
    case pi
    case claude
    case codex
    case copilot

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pi: return "Pi"
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .copilot: return "Copilot"
        }
    }

    var commandTemplate: String {
        switch self {
        case .pi:
            return "pi -ne -ns -p --no-tools --system-prompt \"$VOICEINK_SYSTEM_PROMPT\" \"$VOICEINK_USER_PROMPT\""
        case .claude:
            return "claude -p --model claude-sonnet-5 --effort low \"$VOICEINK_FULL_PROMPT\""
        case .codex:
            return
                "codex exec -m gpt-5.6-luna -c model_reasoning_effort=low --skip-git-repo-check --ephemeral \"$VOICEINK_FULL_PROMPT\""
        case .copilot:
            return "copilot -p \"$VOICEINK_FULL_PROMPT\" -s --no-ask-user --available-tools=__none__ 2>/dev/null"
        }
    }
}

final class LocalCLIService {
    static let commandTemplateKey = "localCLICommandTemplate"
    static let selectedTemplateKey = "localCLISelectedTemplate"
    static let timeoutSecondsKey = "localCLITimeoutSeconds"
    static let defaultTimeoutSeconds: Double = 45

    var commandTemplate: String {
        didSet {
            UserDefaults.standard.set(commandTemplate, forKey: Self.commandTemplateKey)
        }
    }

    var selectedTemplate: LocalCLITemplate {
        didSet {
            UserDefaults.standard.set(selectedTemplate.rawValue, forKey: Self.selectedTemplateKey)
        }
    }

    var timeoutSeconds: Double {
        didSet {
            let clamped = max(5, timeoutSeconds)
            if clamped != timeoutSeconds {
                timeoutSeconds = clamped
                return
            }
            UserDefaults.standard.set(timeoutSeconds, forKey: Self.timeoutSecondsKey)
        }
    }

    var isConfigured: Bool {
        !commandTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init() {
        let savedTemplateRaw = UserDefaults.standard.string(forKey: Self.selectedTemplateKey) ?? ""
        selectedTemplate = LocalCLITemplate(rawValue: savedTemplateRaw) ?? .pi

        commandTemplate = UserDefaults.standard.string(forKey: Self.commandTemplateKey) ?? ""

        let savedTimeout = UserDefaults.standard.double(forKey: Self.timeoutSecondsKey)
        timeoutSeconds = savedTimeout > 0 ? savedTimeout : Self.defaultTimeoutSeconds
    }

    func loadTemplate(_ template: LocalCLITemplate) {
        selectedTemplate = template
        commandTemplate = template.commandTemplate
    }

    func enhance(systemPrompt: String, userPrompt: String) async throws -> String {
        guard isConfigured else {
            throw LocalCLIError.commandNotConfigured
        }

        let fullPrompt = Self.makeFullPrompt(systemPrompt: systemPrompt, userPrompt: userPrompt)
        return try await Self.executeCommand(
            commandTemplate: commandTemplate,
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            fullPrompt: fullPrompt,
            timeout: timeoutSeconds
        )
    }

    static func makeFullPrompt(systemPrompt: String, userPrompt: String) -> String {
        """
        # System Message
        <SYSTEM_MESSAGE>
        \(systemPrompt)
        </SYSTEM_MESSAGE>

        # User Message Payload
        <USER_MESSAGE_PAYLOAD>
        \(userPrompt)
        </USER_MESSAGE_PAYLOAD>
        """
    }

    static func executeCommand(
        commandTemplate: String,
        systemPrompt: String,
        userPrompt: String,
        fullPrompt: String,
        timeout: Double,
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> String {
        guard !commandTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalCLIError.commandNotConfigured
        }
        let usesArgumentPrompt =
            commandTemplate == LocalCLITemplate.codex.commandTemplate
            || commandTemplate == LocalCLITemplate.claude.commandTemplate
        let result = try await LocalCLIProcessRunner.run(
            command: commandTemplate,
            standardInput: usesArgumentPrompt ? nil : Data(fullPrompt.utf8),
            timeout: timeout,
            environment: {
                var environment = inheritedEnvironment
                environment["PATH"] = ShellCommandEnvironment.preferredPATH(fallback: environment["PATH"])
                environment["VOICEINK_SYSTEM_PROMPT"] = systemPrompt
                environment["VOICEINK_USER_PROMPT"] = userPrompt
                environment["VOICEINK_FULL_PROMPT"] = fullPrompt
                return environment
            }
        )
        try Task.checkCancellation()
        let stdout = Self.cleanOutput(String(data: result.stdout, encoding: .utf8) ?? "")
        let stderr = Self.cleanOutput(String(data: result.stderr, encoding: .utf8) ?? "")

        if result.status != 0 {
            let looksLikeCommandNotFound = result.status == 127 || stderr.lowercased().contains("command not found")
            if looksLikeCommandNotFound {
                throw LocalCLIError.commandNotFound(stderr.isEmpty ? commandTemplate : stderr)
            }
            throw LocalCLIError.nonZeroExit(status: Int(result.status), stderr: stderr)
        }
        guard !stdout.isEmpty else { throw LocalCLIError.emptyOutput }
        return stdout
    }

    private static func cleanOutput(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum LocalCLIError: Error, LocalizedError {
    case commandNotConfigured
    case commandNotFound(String)
    case timeout(seconds: Double)
    case nonZeroExit(status: Int, stderr: String)
    case emptyOutput
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case .commandNotConfigured:
            return String(localized: "Local CLI command is not configured. Load a template or enter a command first.")
        case .commandNotFound(let details):
            return String(
                format: String(
                    localized:
                        "Local CLI command was not found. Use an absolute path or fix your shell PATH. Details: %@"),
                details)
        case .timeout(let seconds):
            return String(format: String(localized: "Local CLI command timed out after %lld seconds."), Int64(seconds))
        case .nonZeroExit(let status, let stderr):
            if stderr.isEmpty {
                return String(format: String(localized: "Local CLI command failed with exit code %lld."), Int64(status))
            }
            return String(
                format: String(localized: "Local CLI command failed with exit code %lld: %@"), Int64(status), stderr)
        case .emptyOutput:
            return String(localized: "Local CLI command returned empty output.")
        case .executionFailed(let message):
            return String(format: String(localized: "Failed to execute Local CLI command: %@"), message)
        }
    }
}
