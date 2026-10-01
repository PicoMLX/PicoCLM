import AppKit
import Foundation
import Observation
import PicoContext
import PicoContextMLX
import SwiftUI

@main
struct ContextPlaygroundApp: App {
    @State private var model = PlaygroundModel()

    var body: some Scene {
        WindowGroup("PicoContext Playground") {
            PlaygroundView(model: model)
                .frame(minWidth: 1_000, minHeight: 700)
                .task {
                    if ProcessInfo.processInfo.arguments.contains("--smoke") {
                        await model.runComparison()
                        model.writeSmokeReport()
                    }
                }
        }
        .defaultSize(width: 1_200, height: 850)
    }
}

@Observable @MainActor
final class PlaygroundModel {
    let scope = ContextScope(userID: "playground-user", conversationID: "lamp-order", branchID: "main")
    var baseline: RunReport?
    var editable: RunReport?
    var status = "Ready. The first run downloads a 1 GB local model."
    var running = false
    var progress = 0.0
    private var backend: MLXContextBackend?

    var fixture: ContextSnapshot { PlaygroundFixture.context(scope: scope) }

    func runComparison() async {
        guard !running else { return }
        running = true
        baseline = nil
        editable = nil
        defer { running = false }
        do {
            if backend == nil {
                status = "Loading \(MLXContextBackend.modelID)…"
                let directory = ProcessInfo.processInfo.environment["PICO_CONTEXT_MODEL_DIRECTORY"].map { URL(fileURLWithPath: $0) }
                backend = try await MLXContextBackend.load(directory: directory) { [weak self] fraction in
                    Task { @MainActor in self?.progress = fraction }
                }
            }
            guard let backend else { return }
            status = "Running append-only baseline…"
            let appendOnly = try ContextSession(context: fixture, counter: backend, backend: backend)
            baseline = try await appendOnly.run(mode: .appendOnly)
            status = "Exposing context, requesting an edit, then running the revised input…"
            let editing = try ContextSession(context: fixture, counter: backend, backend: backend)
            editable = try await editing.run()
            status = editable?.failure ?? "Finished. Inspect the context diff and exact next model input below."
        } catch { status = error.localizedDescription }
    }

    func writeSmokeReport() {
        let text = ["Model: \(MLXContextBackend.modelID)", status,
                    baseline.map { Self.summary($0) } ?? "No baseline",
                    editable.map { Self.summary($0) } ?? "No editable run",
                    "EDIT OUTPUT", editable?.attempts.map { $0.modelText + "\n" + $0.arguments }.joined(separator: "\n\n") ?? "",
                    "DIFF", editable?.diff ?? "", "EXACT FINAL INPUT", editable?.finalPrompt?.renderedPrompt ?? ""].joined(separator: "\n\n")
        if let path = ProcessInfo.processInfo.environment["PICO_CONTEXT_SMOKE_REPORT"] {
            do { try text.write(toFile: path, atomically: true, encoding: .utf8) }
            catch { status = error.localizedDescription }
        }
        if let path = ProcessInfo.processInfo.environment["PICO_CONTEXT_SMOKE_IMAGE"],
           let baseline, let editable {
            let renderer = ImageRenderer(content: RunSnapshotView(baseline: baseline, editable: editable))
            renderer.scale = 2
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) {
                do { try png.write(to: URL(fileURLWithPath: path), options: .atomic) }
                catch { status = error.localizedDescription }
            }
        }
        print(text)
    }

    static func summary(_ report: RunReport) -> String {
        """
        \(report.mode.rawValue): \(report.failure ?? "completed")
        Fixture check: \(report.failure == nil && PlaygroundFixture.answerIsCorrect(report.answer) ? "passed" : "failed")
        Completion prompt: \(report.originalPromptTokens.map(String.init) ?? "unavailable") → \(report.finalPrompt?.tokenCount ?? 0) tokens
        Total input: \(report.totalInputTokens); generated: \(report.totalGeneratedTokens); edit calls: \(report.editCallCount)
        Elapsed: \(String(format: "%.2f", report.elapsedSeconds)) s
        Answer: \(report.answer)
        Attempts: \(report.attempts.map { $0.detail }.joined(separator: "; "))
        """
    }
}

/// A reproducible SwiftUI image of the actual live reports, independent of desktop capture permissions.
private struct RunSnapshotView: View {
    let baseline: RunReport
    let editable: RunReport

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("PicoContext · Live MLX run").font(.largeTitle.bold())
            Text(MLXContextBackend.modelID).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 20) {
                snapshotResult(baseline, title: "Append-only")
                snapshotResult(editable, title: "Editable context")
            }
            Text("Working context · revision \(editable.revised.revision)").font(.title2.bold())
            ForEach(editable.revised.records.filter { $0.role == .tool }) { record in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(record.id) · tool · result for \(record.toolCallID ?? "")").font(.headline)
                    Text(record.body).font(.system(.body, design: .monospaced)).lineLimit(3)
                }
            }
            Text("Protected instructions and initial task retained. Next input uses this revision with fresh KV state.")
                .foregroundStyle(.secondary)
            Text("Total usage includes editing overhead. A shorter final prompt is not evidence of a faster run.")
                .font(.caption)
        }
        .padding(30).frame(width: 1_120, alignment: .leading)
        .background(.background)
        .environment(\.colorScheme, .light)
    }

    private func snapshotResult(_ report: RunReport, title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(report.failure == nil && PlaygroundFixture.answerIsCorrect(report.answer) ? "Fixture facts retained ✓" : "Fixture check failed")
            Text("Completion prompt: \(report.originalPromptTokens.map(String.init) ?? "unavailable") → \(report.finalPrompt?.tokenCount ?? 0) tokens")
            Text("Total input: \(report.totalInputTokens) · generated: \(report.totalGeneratedTokens)")
            Text("Edit calls: \(report.editCallCount) · \(report.elapsedSeconds, specifier: "%.2f") seconds")
            Text(report.answer).font(.system(.body, design: .monospaced))
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.08), in: .rect(cornerRadius: 12))
    }
}

struct PlaygroundView: View {
    @Bindable var model: PlaygroundModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("PicoContext").font(.largeTitle.bold())
                        Text("A local model edits the context it will receive on its next call.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Run comparison") { Task { await model.runComparison() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.running)
                }
                Text("Live MLX · \(MLXContextBackend.modelID) · greedy sampling · fresh prompt evaluation")
                    .font(.caption).foregroundStyle(.secondary)
                if model.running { ProgressView(value: model.progress) }
                Text(model.status).textSelection(.enabled)
                HStack(alignment: .top, spacing: 18) {
                    if let baseline = model.baseline { ResultCard(report: baseline, title: "Append-only") }
                    if let editable = model.editable { ResultCard(report: editable, title: "Editable context") }
                }
                HStack(alignment: .top, spacing: 18) {
                    ContextPane(title: "Original context", context: model.fixture)
                    ContextPane(title: "Edited context", context: model.editable?.revised ?? model.fixture)
                }
                if let report = model.editable {
                    DisclosureGroup("Edit diff") { MonospacedText(text: report.diff.isEmpty ? "No edit committed." : report.diff) }
                    ForEach(Array(report.attempts.enumerated()), id: \.offset) { index, attempt in
                        DisclosureGroup("Attempt \(index + 1): \(attempt.detail)") { MonospacedText(text: attempt.modelText + "\n" + attempt.arguments) }
                    }
                    DisclosureGroup("Exact next input · \(report.finalPrompt?.tokenCount ?? 0) tokens", isExpanded: .constant(true)) {
                        MonospacedText(text: report.finalPrompt?.renderedPrompt ?? "No completion call made.")
                    }
                }
            }.padding(24)
        }
    }
}

private struct ResultCard: View {
    let report: RunReport
    let title: String
    var body: some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 8) {
                Text(report.failure == nil && PlaygroundFixture.answerIsCorrect(report.answer) ? "Fixture facts retained ✓" : "Fixture check failed")
                    .font(.headline)
                Text("Prompt: \(report.originalPromptTokens.map(String.init) ?? "unavailable") → \(report.finalPrompt?.tokenCount ?? 0) tokens")
                Text("Total input \(report.totalInputTokens) · generated \(report.totalGeneratedTokens) · edits \(report.editCallCount)")
                Text("\(report.elapsedSeconds, specifier: "%.2f") seconds")
                Text(report.answer.isEmpty ? (report.failure ?? "No answer") : report.answer).textSelection(.enabled)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }
}

private struct ContextPane: View {
    let title: String
    let context: ContextSnapshot
    var body: some View {
        GroupBox("\(title) · revision \(context.revision)") {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(context.records) { record in
                        VStack(alignment: .leading, spacing: 5) {
                            Text("\(record.id) · \(record.role.rawValue)\(record.isProtected ? " · protected" : "")").font(.headline)
                            Text(record.body).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                    }
                }.padding(8)
            }.frame(height: 320)
        }.frame(maxWidth: .infinity)
    }
}

private struct MonospacedText: View {
    let text: String
    var body: some View {
        Text(text).font(.system(.caption, design: .monospaced))
            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(10)
    }
}
