import Foundation
import FoundationModels
import Synchronization

// MARK: - The workflow profile (select the tools, then do the work)
//
// The inverse staging of the removed gather→act profile (git history).
// Where gather→act front-loaded fact collection, this workflow front-loads
// *tool selection*:
//
// - **scope** — the user intent plus the *finishing* (user-visible) tool
//   catalogue, with tool calling DISALLOWED (`tool_choice: none` on an
//   OpenAI-style wire): the manifests are visible but nothing can execute,
//   and the model answers with a structured `ToolSelection` (guided
//   generation — `respond(to:generating:)`): a typed array of tool names,
//   usually one. A dozen output tokens, where even a minimal tool-call
//   envelope costs ~30+. One LLM round; the moment it lands the host has a
//   TYPED selection to drive UI from (the progress-hint moment) before
//   firing the work step.
// - **work** — the selected finishing tools plus only the assistive unit
//   requests *registered on them* (`FinishingTool`). All lookups and
//   all actions happen here. The user intent is re-sent; a cut-index
//   `historyTransform` drops every scope-step entry, so the catalogue and
//   the selection chatter never re-enter the context. The host ends the
//   step in code via `WorkTurnMonitor` the moment a fully-executed turn
//   contains a finishing output.
//
// The selection is the ONLY thing that crosses the stage boundary, and it
// crosses host-side — no model summary, no transcript carry-over.

/// Which step of the workflow the session is in.
public enum WorkflowStage: String, Sendable, Hashable, CaseIterable {
    /// Name the finishing tools the request needs (nothing executes).
    case scope
    /// Do all the work: scoped assistive lookups, then the selected actions.
    case work
}

extension SessionPropertyValues {
    /// The workflow step of this session. Hosts flip it to `.work`
    /// after the scope step's selection lands.
    @SessionPropertyEntry public var workflowStage: WorkflowStage = .scope
}

@available(*, deprecated, message: "workflowStage is declared with @SessionPropertyEntry; read and write `SessionPropertyValues.workflowStage` directly. Raw subscripts through this key use separate storage and no longer reach it.")
public struct WorkflowStageKey: SessionPropertyKey {
    public static var defaultValue: WorkflowStage { .scope }
}

/// A user-visible finishing tool that registers the assistive unit requests
/// needed to resolve its arguments. The scope step selects finishing tools;
/// the work step exposes only the union of the selected tools' registrations
/// — assistive scoping is derived from the selection, never from the task.
public protocol FinishingTool: Tool {
    var registeredAssistiveTools: [any Tool] { get }

    /// User-facing progress text the host's assistant surface shows while the
    /// work step performs this tool's action — e.g. "Creating Entry…",
    /// ellipsis included; localize host-side. `nil` (the default) keeps the
    /// host's generic busy label (typically "Thinking…").
    var progressText: String? { get }
}

extension FinishingTool {
    public var progressText: String? { nil }
}

extension Sequence where Element == any FinishingTool {
    /// The progress text for a validated selection: the FIRST selected tool's
    /// `progressText`. The hint is one line for the whole run, so a
    /// multi-tool selection deliberately shows its first tool's text, never a
    /// list. `nil` — empty selection, unknown name, or a tool without text —
    /// means the host shows its generic busy label.
    public func progressText(forSelection selection: [String]) -> String? {
        guard let selected = selection.first else { return nil }
        return first { $0.name == selected }?.progressText
    }
}

/// Sentinel thrown out of the work step's `respond(...)` the moment its
/// work is done (see `WorkTurnMonitor`), skipping the session loop's
/// closing text turn. Pair with
/// `.transcriptErrorHandlingPolicy(.preserveTranscript)`.
public struct WorkflowStageComplete: Error, Sendable {
    public init() {}
}

/// The scope step's structured reply: the finishing-tool names the request
/// needs — usually one, several only for multi-action requests. Produced by
/// guided generation (`respond(to:generating: ToolSelection.self)`),
/// so the orchestrator holds a TYPED selection the moment step 1 lands —
/// the hook for a per-tool progress view while the work step runs.
@Generable
public struct ToolSelection: Sendable {
    @Guide(description: """
    The names of the task tools needed to complete the user's request, \
    exactly as listed. Usually ONE name; several only when the request \
    asks for several distinct actions.
    """)
    public var toolNames: [String]

    public init(toolNames: [String]) {
        self.toolNames = toolNames
    }

    /// The selection validated against the catalogue, in catalogue order:
    /// exact case-insensitive matches, ignoring surrounding whitespace.
    /// Unknown or decorated names are dropped. An empty result does not grant
    /// access to the full catalogue; ask for a valid selection before acting.
    public func validated(against available: [String]) -> [String] {
        let lowered = Set(toolNames.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        return available.filter { name in
            let needle = name.lowercased()
            return lowered.contains(needle)
        }
    }
}

/// The scope step's reply in the DIRECT-CALL variant of the workflow: the
/// selection plus, optionally, the COMPLETE arguments of the single selected
/// tool — embedded when the model judges the user's request itself supplies
/// every required property (no lookups needed). The host then decides the
/// workflow's shape: arguments present → attempt the call host-side
/// (`WorkflowDirectCall.invoke`); success finishes the workflow with no
/// work step. A decoding failure may fall through to the normal work step;
/// an execution error may follow a side effect and must not be blindly retried.
///
/// Not `@Generable` on purpose: `arguments` is a free-form object whose real
/// schema is the selected tool's — a fixed reply schema cannot express it.
/// The reply contract rides in the prompt (hand-rendered, like the plain
/// selection's) and parses host-side through `GeneratedContent`.
public struct DirectToolSelection: Sendable {
    public var toolNames: [String]
    /// Arguments for the single selected tool, exactly as the model emitted
    /// them; `nil` when the model declined to embed (the normal case) or
    /// emitted a non-object.
    public var arguments: GeneratedContent?

    public init(toolNames: [String], arguments: GeneratedContent? = nil) {
        self.toolNames = toolNames
        self.arguments = arguments
    }

    public init(_ content: GeneratedContent) throws {
        self.toolNames = try content.value([String].self, forProperty: "toolNames")
        if let embedded = try? content.value(
            GeneratedContent.self, forProperty: "arguments"
        ), case .structure = embedded.kind {
            self.arguments = embedded
        } else {
            self.arguments = nil
        }
    }

    /// Same catalogue validation as the plain `ToolSelection`.
    public func validated(against available: [String]) -> [String] {
        ToolSelection(toolNames: toolNames).validated(against: available)
    }
}

/// Host-side execution of a scope-step direct call: decode the embedded
/// arguments through the tool's own typed `Arguments` (the SAME path a
/// session tool call takes — guides, optionality, and the tool's own
/// argument validation all apply) and run the tool. Throws whatever the
/// decode or the tool throws. Hosts must distinguish decoding failure from
/// execution failure: retrying the latter can duplicate a committed action.
public enum WorkflowDirectCall {
    public static func invoke<T: Tool>(
        _ tool: T, arguments: GeneratedContent
    ) async throws -> String {
        let typed = try T.Arguments(arguments)
        let output = try await tool.call(arguments: typed)
        return String(describing: output)
    }
}

/// The workflow profile. Stage-switched on a session property; the
/// work step's tool set is produced per request by a closure, because it is
/// derived from the scope step's runtime selection.
public struct WorkflowProfile: LanguageModelSession.DynamicProfile {
    @SessionProperty(\.workflowStage) private var stage

    private let scopeInstructions: @Sendable () -> String
    private let workInstructions: @Sendable () -> String
    private let catalogue: [any Tool]
    private let workTools: @Sendable () -> [any Tool]
    private let scopeResponseTokenCap: Int
    private let scopeIncludesArgumentSchemas: Bool

    /// - Parameters:
    ///   - scopeInstructions: Scope-step instructions (name the tools in
    ///     plain text, nothing else).
    ///   - workInstructions: Work-step instructions, evaluated per request —
    ///     inject local deictic state here.
    ///   - catalogue: The full finishing-tool catalogue — what the scope
    ///     step sees (visible, not callable).
    ///   - workTools: The work step's tool set, evaluated per request: the
    ///     selected finishing tools plus their registered assistive tools.
    ///   - scopeResponseTokenCap: Output budget for the scope step's text
    ///     reply. A selection is a few tool names; the cap is the backstop
    ///     against rambling (a truncated reply still substring-parses).
    ///     The direct-call variant needs headroom for embedded arguments —
    ///     raise it when `scopeIncludesArgumentSchemas` is on.
    ///   - scopeIncludesArgumentSchemas: The DIRECT-CALL variant's switch:
    ///     render each catalogue tool's argument schema into the scope
    ///     instructions so the model can embed complete arguments for the
    ///     selected tool in its reply (`DirectToolSelection`). Off by
    ///     default — the plain selection doesn't need schemas and the
    ///     catalogue stays ~name+description cheap.
    public init(
        scopeInstructions: @escaping @Sendable () -> String,
        workInstructions: @escaping @Sendable () -> String,
        catalogue: [any Tool],
        workTools: @escaping @Sendable () -> [any Tool],
        scopeResponseTokenCap: Int = 64,
        scopeIncludesArgumentSchemas: Bool = false
    ) {
        self.scopeInstructions = scopeInstructions
        self.workInstructions = workInstructions
        self.catalogue = catalogue
        self.workTools = workTools
        self.scopeResponseTokenCap = scopeResponseTokenCap
        self.scopeIncludesArgumentSchemas = scopeIncludesArgumentSchemas
    }

    public var body: some LanguageModelSession.DynamicProfile {
        if stage == .scope {
            // Manifests visible, calls impossible: the model must answer in
            // text, and a bare tool-name list costs ~5–15 output tokens
            // where even a minimal tool-call envelope bills ~30+. The
            // catalogue is rendered INTO the instructions — the runtime
            // strips registered tools from the request when tool calling
            // is disallowed, so listing them as tools would send nothing.
            LanguageModelSession.Profile {
                Instructions(
                    scopeInstructions() + "\n\n" + Self.renderedCatalogue(
                        catalogue,
                        includeArgumentSchemas: scopeIncludesArgumentSchemas
                    )
                )
            }
            .toolCallingMode(.disallowed)
            .maximumResponseTokens(scopeResponseTokenCap)
        } else {
            LanguageModelSession.Profile {
                Instructions(workInstructions())
                workTools()
            }
            .toolCallingMode(.allowed)
        }
    }

    /// The scope step's tool catalogue as instruction text — name and
    /// manifest description per finishing tool, the material the router
    /// selects from. With `includeArgumentSchemas` (the direct-call
    /// variant), each tool also carries its argument schema (the official
    /// `GenerationSchema` JSON encoding) — the model cannot embed complete
    /// arguments for a tool whose shape it has never seen.
    private static func renderedCatalogue(
        _ tools: [any Tool], includeArgumentSchemas: Bool = false
    ) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return "Task tools:\n" + tools
            .map { tool in
                var line = "- \(tool.name): \(tool.description)"
                if includeArgumentSchemas,
                   let schema = try? encoder.encode(tool.parameters) {
                    line += "\n  arguments schema: \(String(decoding: schema, as: UTF8.self))"
                }
                return line
            }
            .joined(separator: "\n")
    }

    /// Parses a selection out of the scope step's text reply: every
    /// available tool name that appears in the text, in catalogue order.
    /// Case-insensitive identifier matches tolerate separators and prose,
    /// without matching a shorter tool name inside a longer one. This is a
    /// text parser, not an authorization decision; prefer `ToolSelection`.
    public static func parseSelection(
        _ raw: String, from available: [String]
    ) -> [String] {
        let identifiers = Set(raw.lowercased().split {
            !$0.isLetter && !$0.isNumber && $0 != "_" && $0 != "-"
        }.map(String.init))
        return available.filter { identifiers.contains($0.lowercased()) }
    }

    /// Per-stage history reset: each stage sees ONLY its own instructions and
    /// the user prompt. Tool chatter is dropped at every stage boundary. Use
    /// this when the work step is single-shot (the scoped-workflow style: bound
    /// args + an optional `AskTool`, no intra-stage lookup turns). For the
    /// classic multi-round-trip work step (parallel lookups → action turn),
    /// stick with the cut-index transform — this helper would erase the
    /// lookup results between turns and break it.
    public static func resetHistory(
        _ entries: [Transcript.Entry], stage: WorkflowStage
    ) -> [Transcript.Entry] {
        _ = stage // future-proof: both stages have the same retention today
        return entries.compactMap { entry in
            switch entry {
            case .instructions, .prompt:
                return entry
            case .toolCalls, .toolOutput, .response, .reasoning:
                return nil
            @unknown default:
                return nil
            }
        }
    }
}

/// Host-side stop for the work step: ends the session the moment its work
/// is done — no completion signal from the model, no closing text turn.
///
/// Feed it from the profile hooks. The runtime fires ALL of a parallel
/// batch's `onToolCall`s before the first tool executes (verified on the
/// OS 27 SDK), so the monitor can tell when a turn is fully executed
/// without ever cancelling a batched sibling call:
///
/// ```swift
/// .onToolCall  { call in if inWorkStep { monitor.recordCall(call) } … }
/// .onToolOutput { call, _ in
///     if inWorkStep, monitor.recordOutput(call) { throw WorkflowStageComplete() }
/// }
/// ```
///
/// Completion = the current turn's outputs all landed AND at least one of
/// them came from a finishing (user-visible action) tool. A turn of pure
/// lookups never stops the session; a model that replies in text instead of
/// acting (a refusal) simply ends the respond normally.
public final class WorkTurnMonitor: Sendable {
    /// One work turn's tallies; reset together when a new turn starts.
    private struct TurnState {
        var callsInTurn = 0
        var outputsInTurn = 0
        var finishingOutputsInTurn = 0
    }

    private let finishingNames: Set<String>
    private let state = Mutex(TurnState())

    public init(finishingToolNames: some Sequence<String>) {
        self.finishingNames = Set(finishingToolNames)
    }

    /// Call from `onToolCall`. Starts a new turn when the previous one is
    /// fully executed.
    public func recordCall(_ call: Transcript.ToolCall) {
        state.withLock { state in
            if state.outputsInTurn == state.callsInTurn {
                state = TurnState()
            }
            state.callsInTurn += 1
        }
    }

    /// Call from `onToolOutput`. Returns `true` the moment the work is done
    /// — the turn is fully executed and performed at least one finishing
    /// action — i.e. the moment to throw `WorkflowStageComplete`.
    public func recordOutput(_ call: Transcript.ToolCall) -> Bool {
        state.withLock { state in
            state.outputsInTurn += 1
            if finishingNames.contains(call.toolName) {
                state.finishingOutputsInTurn += 1
            }
            return state.outputsInTurn == state.callsInTurn
                && state.finishingOutputsInTurn > 0
        }
    }
}
