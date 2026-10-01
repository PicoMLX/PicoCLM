import Foundation
import PicoContext
import PicoContextDiagnostics
#if PICO_CONTEXT_HAS_MLX
import PicoContextMLX
#endif

@main
struct ContextEvaluate {
    static func main() async {
        do { try await execute() }
        catch {
            FileHandle.standardError.write(Data("ContextEvaluate: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    static func execute() async throws {
        var arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--help"] {
            print("""
            ContextEvaluate [--backend deterministic|mlx] [--config path.json] [--output path.json]
              --model-directory path  Required for MLX; uses local files only, never downloads.
            Config defaults: two seeds, four steps, 12 noise lines, three counterbalanced repetitions.
            Deterministic defaults use a byte counter and larger byte allowances, not model tokens.
            Exit codes: 0 all episodes passed; 2 graded/budget failures (JSON preserved); 1 invalid setup.
            """)
            return
        }
        var options: [String: String] = [:]
        let known: Set<String> = ["--backend", "--config", "--output", "--model-directory"]
        while !arguments.isEmpty {
            let flag = arguments.removeFirst()
            guard known.contains(flag), options[flag] == nil, !arguments.isEmpty else {
                throw ContextError.invalid("unknown, duplicate or missing option: \(flag)")
            }
            options[flag] = arguments.removeFirst()
        }
        let backendName = options["--backend"] ?? "deterministic"
        guard ["deterministic", "mlx"].contains(backendName) else { throw ContextError.invalid("unknown backend") }
        var configuration = EvaluationConfiguration()
        if let path = options["--config"] {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 1_000_001) ?? Data()
            guard data.count <= 1_000_000 else { throw ContextError.invalid("configuration exceeds 1 MB") }
            configuration = try JSONDecoder().decode(EvaluationConfiguration.self, from: data)
        } else if backendName == "deterministic" {
            configuration.limits = EvaluationLimits(contextWindow: 32_768, turnTokens: 500_000, episodeTokens: 2_000_000)
        }
        try configuration.validate()
        let counter: any TokenCounting
        let backend: any ContextModelBackend
        let model: String
        let revision: String
        if backendName == "mlx" {
            #if PICO_CONTEXT_HAS_MLX
            guard let directory = options["--model-directory"] else {
                throw ContextError.invalid("MLX requires --model-directory pointing at the existing Qwen3 1.7B cache")
            }
            let url = URL(fileURLWithPath: directory).resolvingSymlinksInPath()
            let loaded = try await MLXContextBackend.load(directory: url)
            counter = loaded; backend = loaded; model = MLXContextBackend.modelID
            // A caller-supplied directory does not prove a particular remote snapshot.
            revision = "unverified-local-files"
            #else
            throw ContextError.invalid("MLX is opt-in; use Scripts/run-evaluation.sh with --model-directory")
            #endif
        } else {
            guard options["--model-directory"] == nil else { throw ContextError.invalid("--model-directory requires MLX") }
            counter = DiagnosticByteCounter(); backend = DeterministicNotebookBackend()
            model = "deterministic-notebook"; revision = "1"
        }
        let environment = ProcessInfo.processInfo.environment
        let provenance = EvaluationProvenance(backend: backendName, model: model, modelRevision: revision,
                                             sampling: backendName == "mlx" ? "greedy, temperature 0, fresh KV" : "deterministic, UTF-8 byte accounting",
                                             sourceRevision: environment["PICO_CONTEXT_SOURCE_REVISION"] ?? "unknown",
                                             swiftVersion: environment["PICO_CONTEXT_SWIFT_VERSION"] ?? "unknown")
        let scope = ContextScope(userID: "evaluation", conversationID: configuration.scenario.rawValue, branchID: "comparison")
        let report = try await EvaluationRunner(counter: counter, backend: backend).run(configuration, scope: scope, provenance: provenance) { result in
            print("\(result.order): seed \(result.seed), repetition \(result.repetition), \(result.policy.rawValue): context \(result.retainedCorrectSteps)/\(result.plannedSteps), answer \(result.answerCorrectSteps)/\(result.plannedSteps), input \(result.inputTokens), output \(result.generatedTokens)\(result.failure.map { ", failure: " + $0 } ?? "")")
        }
        let path = options["--output"] ?? "/tmp/picocontext-evaluation.json"
        try report.json().write(to: URL(fileURLWithPath: path), options: .atomic)
        print("Saved \(path)")
        if report.results.contains(where: { !$0.passed }) { exit(2) }
    }
}
