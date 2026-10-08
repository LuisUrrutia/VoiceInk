import Darwin
import Foundation
import FluidAudio

struct OutputJob {
    let input: URL
    let output: URL?
}

enum OutputFiles {
    static func identity(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path.precomposedStringWithCanonicalMapping.lowercased()
    }

    static func sameFile(_ left: URL, _ right: URL) -> Bool {
        if identity(left) == identity(right) { return true }
        guard let a = try? FileManager.default.attributesOfItem(atPath: left.path),
              let b = try? FileManager.default.attributesOfItem(atPath: right.path),
              let aDevice = a[.systemNumber] as? NSNumber, let bDevice = b[.systemNumber] as? NSNumber,
              let aInode = a[.systemFileNumber] as? NSNumber, let bInode = b[.systemFileNumber] as? NSNumber else { return false }
        return aDevice == bDevice && aInode == bInode
    }

    static func plan(_ options: Options) throws -> [OutputJob] {
        var directory: ObjCBool = false
        let exists = options.output.map { FileManager.default.fileExists(atPath: $0.path, isDirectory: &directory) } ?? false
        if options.inputs.count > 1, exists && !directory.boolValue {
            throw CLIError.message("Batch --output must be a directory")
        }
        let directoryOutput = options.inputs.count > 1 || directory.boolValue
        let protected = options.inputs + [options.preferences, options.dictionary].compactMap { $0 }
        var outputs = Set<String>()
        return try options.inputs.map { input in
            let output = options.output.map {
                directoryOutput ? $0.appendingPathComponent(input.deletingPathExtension().lastPathComponent + "." + options.format.rawValue) : $0
            }
            if let output {
                guard !protected.contains(where: { sameFile(output, $0) }) else {
                    throw CLIError.message("Output would overwrite an input or settings snapshot: \(output.path)")
                }
                guard outputs.insert(identity(output)).inserted else {
                    throw CLIError.message("Inputs have colliding output names: \(output.path). Process them separately.")
                }
            }
            return OutputJob(input: input, output: output)
        }
    }

    static func exists(_ url: URL) throws -> Bool {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) else { return false }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw CLIError.message("Output exists but is not a regular file: \(url.path)")
        }
        return true
    }

    static func write(_ data: Data, to url: URL, skipExisting: Bool, protected: [URL]) throws {
        guard !protected.contains(where: { sameFile(url, $0) }) else { throw CLIError.message("Output now aliases a protected input") }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if skipExisting {
            let temporary = directory.appendingPathComponent(".voiceink-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try data.write(to: temporary, options: .withoutOverwriting)
            let status = renameatx_np(AT_FDCWD, temporary.path, AT_FDCWD, url.path, UInt32(RENAME_EXCL))
            if status != 0 {
                if errno == EEXIST, try exists(url) { return }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } else {
            try data.write(to: url, options: .atomic)
        }
    }
}

struct BatchRunner {
    typealias Processor = (URL) async throws -> Transcript
    let makeProcessor: () async throws -> Processor
    let stdout: (Data) -> Void
    let stderr: (String) -> Void

    func run(_ options: Options, jobs: [OutputJob]) async -> Int32 {
        var processor: Processor?
        var failures = false
        let protected = options.inputs + [options.preferences, options.dictionary].compactMap { $0 }
        for job in jobs {
            do {
                if options.skipExisting, let output = job.output, try OutputFiles.exists(output) {
                    if !options.quiet { stderr("Skipping \(job.input.path)") }
                    continue
                }
                if !options.quiet { stderr("Transcribing \(job.input.path)") }
                if processor == nil { processor = try await makeProcessor() }
                guard let processor else { throw CLIError.message("Transcriber is unavailable") }
                let result = try await processor(job.input)
                let data = try result.render(options.format)
                if let output = job.output {
                    try OutputFiles.write(data, to: output, skipExisting: options.skipExisting, protected: protected)
                } else { stdout(data) }
            } catch {
                failures = true
                stderr("\(job.input.path): \(error.localizedDescription)")
            }
        }
        return failures ? 1 : 0
    }
}

public enum CLIApplication {
    public static func run(arguments: [String], stdout: @escaping (Data) -> Void,
                           stderr: @escaping (String) -> Void) async -> Int32 {
        let options: Options
        let jobs: [OutputJob]
        do {
            options = try Options.parse(arguments)
            if options.help { stdout(Data((Options.usage + "\n").utf8)); return 0 }
            if options.showVersion { stdout(Data((Options.version + "\n").utf8)); return 0 }
            jobs = try OutputFiles.plan(options)
        } catch {
            stderr(error.localizedDescription)
            stderr(Options.usage)
            return 2
        }
        AppLogger.minimumLevel = .warning
        AppLogger.mirrorsToConsole = false
        var transcriber: Transcriber?
        let runner = BatchRunner(makeProcessor: {
            let settings = try Settings.load(options)
            if options.dictionary == nil, !options.noReplacements, !options.quiet {
                stderr("No Dictionary export supplied; no word replacements. Use --dictionary PATH (\(options.namespace.storeDirectoryName) store remains unopened).")
            }
            let engine = try await Transcriber(options: options, settings: settings, log: { if !options.quiet { stderr($0) } })
            transcriber = engine
            return { url in try await engine.transcribe(AudioDecoder.decode(url)) }
        }, stdout: stdout, stderr: stderr)
        let code = await runner.run(options, jobs: jobs)
        await transcriber?.cleanup()
        return code
    }
}
