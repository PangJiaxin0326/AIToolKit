import Foundation
import FoundationModels
import Testing
@testable import AIToolKit

// MARK: - Probe model: a scripted executor that records every request

/// Global recorder, reachable from the runtime-constructed executor only via
/// the model configuration's `scriptID`.
private final class ProbeLog: @unchecked Sendable {
    static let shared = ProbeLog()
    private let lock = NSLock()
    private var _requests: [String: [[String]]] = [:]

    func record(request rendered: [String], for id: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        _requests[id, default: []].append(rendered)
        return _requests[id]!.count - 1
    }

    func requests(for id: String) -> [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return _requests[id] ?? []
    }
}

private func render(_ entry: Transcript.Entry) -> String {
    func text(_ segments: [Transcript.Segment]) -> String {
        segments.compactMap { segment -> String? in
            if case .text(let t) = segment { return t.content }
            return nil
        }.joined(separator: "\n")
    }
    switch entry {
    case .instructions(let instructions):
        return "inst:" + text(instructions.segments)
    case .prompt(let prompt):
        return "prompt:" + text(prompt.segments)
    case .response(let response):
        return "resp:" + text(response.segments)
    case .toolCalls(let calls):
        return "calls:" + calls.map(\.toolName).joined(separator: "+")
    case .toolOutput(let output):
        return "out:" + output.toolName
    case .reasoning:
        return "reasoning"
    @unknown default:
        return "?"
    }
}

private struct ProbeConfiguration: Hashable, Sendable {
    var scriptID: String
}

private struct ProbeLanguageModel: LanguageModel {
    typealias Executor = ProbeExecutor
    var configuration: ProbeConfiguration

    var capabilities: LanguageModelCapabilities {
        LanguageModelCapabilities(capabilities: [.toolCalling, .guidedGeneration])
    }

    var executorConfiguration: ProbeConfiguration { configuration }
}

private struct ProbeExecutor: LanguageModelExecutor {
    typealias Configuration = ProbeConfiguration
    typealias Model = ProbeLanguageModel

    let configuration: ProbeConfiguration

    init(configuration: ProbeConfiguration) throws {
        self.configuration = configuration
    }

    nonisolated(nonsending) func respond(
        to request: LanguageModelExecutorGenerationRequest,
        model: ProbeLanguageModel,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        let rendered = request.transcript.map(render)
        _ = ProbeLog.shared.record(request: rendered, for: configuration.scriptID)
        if request.schema != nil {
            // Scope step: guided selection.
            await channel.send(.response(
                entryID: UUID().uuidString,
                action: .appendText(#"{"toolNames":["send_message"]}"#, tokenCount: 9)
            ))
        } else if !rendered.contains(where: { $0.hasPrefix("out:find_contact") }) {
            // Work turn 1: the dependent lookup.
            await channel.send(.toolCalls(
                entryID: UUID().uuidString,
                action: .toolCall(
                    id: UUID().uuidString,
                    name: "find_contact",
                    action: .appendArguments(#"{"value":"Alex"}"#, tokenCount: 4)
                )
            ))
        } else if !rendered.contains(where: { $0.hasPrefix("out:send_message") }) {
            // Work turn 2: the finishing action, fed by the lookup.
            await channel.send(.toolCalls(
                entryID: UUID().uuidString,
                action: .toolCall(
                    id: UUID().uuidString,
                    name: "send_message",
                    action: .appendArguments("{}", tokenCount: 1)
                )
            ))
        } else {
            // A call after the action turn: the host stop should prevent this.
            await channel.send(.response(
                entryID: UUID().uuidString,
                action: .appendText("UNEXPECTED-CLOSING-TURN", tokenCount: 3)
            ))
        }
    }
}

// MARK: - Probe tools

private struct ProbeLookupTool: AssistiveTool {
    typealias Arguments = TextArgument
    let name = "find_contact"
    let description = "Resolve a contact name to its id."
    func call(arguments: TextArgument) async throws -> String { "c_1" }
}

private struct ProbeSendTool: FinishingTool {
    let name = "send_message"
    let description = "Send a message."
    var registeredAssistiveTools: [any Tool] { [ProbeLookupTool()] }
    func call(arguments: EmptyArguments) async throws -> String { "m_1" }
}

private struct ProbeEntryTool: FinishingTool {
    let name = "create_entry"
    let description = "Create a journal entry."
    var registeredAssistiveTools: [any Tool] { [] }
    func call(arguments: EmptyArguments) async throws -> String { "e_1" }
}

// MARK: - Host-side run state (mirrors the AGENTS.md recipe verbatim)

private final class ProbeRunState: @unchecked Sendable {
    private let lock = NSLock()
    private var _stage: WorkflowStage = .scope
    private var _selection: [String] = []
    private var _cutIndex = 0

    var stage: WorkflowStage {
        get { lock.lock(); defer { lock.unlock() }; return _stage }
        set { lock.lock(); _stage = newValue; lock.unlock() }
    }
    var selection: [String] {
        get { lock.lock(); defer { lock.unlock() }; return _selection }
        set { lock.lock(); _selection = newValue; lock.unlock() }
    }
    var cutIndex: Int {
        get { lock.lock(); defer { lock.unlock() }; return _cutIndex }
        set { lock.lock(); _cutIndex = newValue; lock.unlock() }
    }
}

@Suite struct WorkflowSessionProbeTests {
    /// Drives one workflow run exactly the way the hosts do (scope respond →
    /// flip + cut → work respond, host-stopped), returning the run outcome.
    private func runWorkflow(
        intent: String,
        model: ProbeLanguageModel
    ) async throws -> String {
        let finishing: [any FinishingTool] = [ProbeEntryTool(), ProbeSendTool()]
        let finishingNames = finishing.map(\.name)
        let state = ProbeRunState()
        let monitor = WorkTurnMonitor(finishingToolNames: finishingNames)

        let profile = WorkflowProfile(
            scopeInstructions: { "SCOPE-INSTR name the tools" },
            workInstructions: { "WORK-INSTR do the job" },
            catalogue: finishing,
            workTools: {
                let selection = state.selection
                let chosen: [any FinishingTool] = selection.isEmpty
                    ? finishing
                    : finishing.filter { selection.contains($0.name) }
                var tools: [any Tool] = chosen
                var seen = Set(chosen.map(\.name))
                for tool in chosen {
                    for assistive in tool.registeredAssistiveTools
                    where !seen.contains(assistive.name) {
                        seen.insert(assistive.name)
                        tools.append(assistive)
                    }
                }
                return tools
            }
        )
        .model(model)
        .historyTransform { entries in
            let cut = state.cutIndex
            guard cut > 0 else { return entries }
            return entries.enumerated().compactMap { index, entry in
                if index == 0, case .instructions = entry { return entry }
                return index >= cut ? entry : nil
            }
        }
        .onToolCall { call in
            if state.stage == .work { monitor.recordCall(call) }
        }
        .onToolOutput { call, _ in
            guard state.stage == .work else { return }
            if monitor.recordOutput(call) {
                throw WorkflowStageComplete()
            }
        }
        .transcriptErrorHandlingPolicy(.preserveTranscript)

        let session = LanguageModelSession(profile: profile)
        let scopePrompt = """
        User request: \(intent)

        Select the task tools this request needs.
        """
        let selection = try await session.respond(
            to: scopePrompt, generating: ToolSelection.self
        ).content
        state.selection = selection.validated(against: finishingNames)
        state.cutIndex = session.transcript.count
        state.stage = .work
        session.properties.workflowStage = .work

        let workPrompt = """
        User request: \(intent)

        Complete this request now.
        """
        do {
            let text = try await session.respond(to: workPrompt).content
            return "text:\(text)"
        } catch {
            let unwrapped =
                (error as? LanguageModelSession.ToolCallError)?.underlyingError ?? error
            if unwrapped is WorkflowStageComplete { return "completed" }
            throw error
        }
    }

    @Test func consecutiveWorkflowsAreIndependent() async throws {
        let scriptID = "probe-\(UUID().uuidString)"
        let model = ProbeLanguageModel(configuration: .init(scriptID: scriptID))

        let outcomeA = try await runWorkflow(intent: "INTENT-A", model: model)
        let outcomeB = try await runWorkflow(intent: "INTENT-B", model: model)

        let requests = ProbeLog.shared.requests(for: scriptID)

        #expect(outcomeA == "completed")
        #expect(outcomeB == "completed")
        try #require(requests.count == 6, "expected 3 LLM calls per workflow, got \(requests)")

        // Work turn 1 (the lookup turn) must see work instructions + work
        // prompt only — no scope leftovers.
        let workA1 = requests[1].joined(separator: "\n")
        #expect(workA1.contains("inst:WORK-INSTR"), "work step ran without work instructions: \(workA1)")
        #expect(!workA1.contains("SCOPE-INSTR"), "scope instructions leaked into the work step: \(workA1)")
        #expect(!workA1.contains("Select the task tools"), "scope prompt leaked past the cut: \(workA1)")

        // Work turn 2 (the action turn) must still carry the work prompt and
        // the lookup turn — the cut must never eat the work step's own
        // history — and still no scope leftovers.
        let workA2 = requests[2].joined(separator: "\n")
        #expect(workA2.contains("prompt:User request: INTENT-A"), "the cut ate the work prompt: \(workA2)")
        #expect(workA2.contains("calls:find_contact"), "the cut ate the work step's own tool call: \(workA2)")
        #expect(workA2.contains("out:find_contact"), "the cut ate the work step's own tool output: \(workA2)")
        #expect(!workA2.contains("SCOPE-INSTR"), "scope instructions leaked into the action turn: \(workA2)")
        #expect(!workA2.contains("Select the task tools"), "scope prompt leaked into the action turn: \(workA2)")

        // Workflow B must not see anything from workflow A.
        let scopeB = requests[3].joined(separator: "\n")
        let workB1 = requests[4].joined(separator: "\n")
        let workB2 = requests[5].joined(separator: "\n")
        #expect(!scopeB.contains("INTENT-A"), "workflow B's scope step saw workflow A: \(scopeB)")
        #expect(!workB1.contains("INTENT-A"), "workflow B's work step saw workflow A: \(workB1)")
        #expect(!workB2.contains("INTENT-A"), "workflow B's action turn saw workflow A: \(workB2)")
        #expect(
            !scopeB.contains("calls:") && !scopeB.contains("out:"),
            "workflow B's scope step saw historical tool calling: \(scopeB)"
        )
        #expect(workB1.contains("inst:WORK-INSTR"), "workflow B's work step ran without work instructions: \(workB1)")
        #expect(!workB1.contains("SCOPE-INSTR"), "scope instructions leaked into workflow B's work step: \(workB1)")
    }
}
