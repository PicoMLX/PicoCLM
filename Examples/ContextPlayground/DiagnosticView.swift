import PicoContext
import PicoContextDiagnostics
import PicoContextMLX
import SwiftUI

struct DiagnosticResultsView: View {
    let baseline: DiagnosticReport?
    let editable: DiagnosticReport?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 18) {
                if let baseline { DiagnosticCard(report: baseline, title: "Append-only") }
                if let editable { DiagnosticCard(report: editable, title: "Editable context") }
            }
            if let report = editable ?? baseline {
                HStack(alignment: .top, spacing: 18) {
                    ContextPane(title: "Original transcript", context: report.original)
                    ContextPane(title: "Working context", context: report.revised)
                }
                ForEach(report.steps, id: \.step.id) { step in
                    DisclosureGroup("\(step.step.id) · retained \(step.retainedCorrect ? "✓" : "✗") · answer \(step.answerCorrect ? "✓" : "✗")") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Expected state: \(Self.facts(step.step.expectedFacts))")
                            Text("Retained state: \(Self.facts(step.retainedFacts))")
                            if let run = step.run {
                                Text("Answer: \(run.answer)")
                                Text("Completion prompt \(run.runStartPromptTokens) → \(run.finalPrompt?.tokenCount ?? 0) tokens; input \(run.totalInputTokens), generated \(run.totalGeneratedTokens)")
                                ForEach(Array(run.attempts.enumerated()), id: \.offset) { _, attempt in
                                    Text(attempt.detail).font(.caption)
                                }
                                DisclosureGroup("Context diff") { MonospacedText(text: run.diff) }
                                DisclosureGroup("Exact next input") { MonospacedText(text: run.finalPrompt?.renderedPrompt ?? "No completion call made.") }
                            }
                            if let failure = step.failure { Text(failure).foregroundStyle(.red) }
                        }.textSelection(.enabled).padding(8)
                    }
                }
            }
        }
    }

    static func facts(_ values: [String: String]) -> String {
        values.keys.sorted().map { "\($0)=\(values[$0]!)" }.joined(separator: "; ")
    }

    static func summary(_ report: DiagnosticReport) -> String {
        """
        \(report.title) · \(report.mode.rawValue): \(report.failure ?? "completed")
        Retained context: \(report.steps.filter(\.retainedCorrect).count)/\(report.steps.count); exact answers: \(report.steps.filter(\.answerCorrect).count)/\(report.steps.count)
        Total input: \(report.totalInputTokens); generated: \(report.totalGeneratedTokens); elapsed: \(report.elapsedSeconds) s
        \(report.steps.map { step in
            "\(step.step.id): retained=\(step.retainedCorrect), answer=\(step.answerCorrect), prompt=\(step.run?.runStartPromptTokens ?? 0)->\(step.run?.finalPrompt?.tokenCount ?? 0), edits=\(step.run?.editCallCount ?? 0), keeps=\(step.run?.keepCallCount ?? 0)"
        }.joined(separator: "\n"))
        """
    }
}

private struct DiagnosticCard: View {
    let report: DiagnosticReport
    let title: String
    var body: some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 8) {
                Text(report.passed ? "Every context and answer check passed ✓" : "Inspect failed checks below")
                    .font(.headline)
                Text("Context \(report.steps.filter(\.retainedCorrect).count)/\(report.steps.count) · answers \(report.steps.filter(\.answerCorrect).count)/\(report.steps.count)")
                ForEach(report.steps, id: \.step.id) { step in
                    Text("\(step.step.id): \(step.run?.runStartPromptTokens ?? 0) → \(step.run?.finalPrompt?.tokenCount ?? 0) prompt tokens")
                        .font(.system(.caption, design: .monospaced))
                }
                Text("Total input \(report.totalInputTokens) · generated \(report.totalGeneratedTokens)")
                Text("\(report.elapsedSeconds, specifier: "%.2f") seconds")
                if let failure = report.failure { Text(failure).foregroundStyle(.red) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }
}

/// Render only real completed reports; independent of desktop capture permissions.
struct DiagnosticSnapshotView: View {
    let baseline: DiagnosticReport
    let editable: DiagnosticReport
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("PicoContext · \(editable.title)").font(.largeTitle.bold())
            Text("Live MLX · \(MLXContextBackend.modelID)").foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 20) {
                snapshotCard(baseline, title: "Append-only")
                snapshotCard(editable, title: "Editable context")
            }
            Text("Retained state after every incoming update").font(.title2.bold())
            ForEach(editable.steps, id: \.step.id) { step in
                Text("\(step.step.id) · \(DiagnosticResultsView.facts(step.retainedFacts))")
                    .font(.system(.body, design: .monospaced))
            }
            Text("Caller requests and model answers append to one session. Protected roles and complete tool links remain intact.")
                .foregroundStyle(.secondary)
            Text("Original diagnostics, not official ContextBench scores. All editing overhead is included; fresh KV state on every call.")
                .font(.caption)
        }.padding(30).frame(width: 1_120, alignment: .leading)
            .background(.background).environment(\.colorScheme, .light)
    }

    private func snapshotCard(_ report: DiagnosticReport, title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title2.bold())
            Text("Context \(report.steps.filter(\.retainedCorrect).count)/\(report.steps.count) · answers \(report.steps.filter(\.answerCorrect).count)/\(report.steps.count)")
                .font(.headline)
            ForEach(report.steps, id: \.step.id) { step in
                Text("\(step.step.id) · \(step.run?.runStartPromptTokens ?? 0) → \(step.run?.finalPrompt?.tokenCount ?? 0) prompt tokens")
                    .font(.system(.body, design: .monospaced))
            }
            Text("Total input \(report.totalInputTokens) · generated \(report.totalGeneratedTokens)")
            Text("\(report.elapsedSeconds, specifier: "%.2f") seconds")
            if let failure = report.failure { Text(failure).foregroundStyle(.red) }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.gray.opacity(0.08), in: .rect(cornerRadius: 12))
    }
}
