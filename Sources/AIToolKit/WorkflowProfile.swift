import Foundation
import FoundationModels

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

public struct WorkflowStageKey: SessionPropertyKey {
    public static var defaultValue: WorkflowStage { .scope }
}

extension SessionPropertyValues {
    /// The workflow step of this session. Hosts flip it to `.work`
    /// after the scope step's selection lands.
    public var workflowStage: WorkflowStage {
        get { self[WorkflowStageKey.self] }
        set { self[WorkflowStageKey.self] = newValue }
    }
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
    /// exact case-insensitive matches plus substring salvage for decorated
    /// items ("use send_message"); unknown names are dropped. An empty
    /// result means the host should fall back to the full catalogue.
    public func validated(against available: [String]) -> [String] {
        let lowered = toolNames.map { $0.lowercased() }
        return available.filter { name in
            let needle = name.lowercased()
            return lowered.contains { $0 == needle || $0.contains(needle) }
        }
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
    public init(
        scopeInstructions: @escaping @Sendable () -> String,
        workInstructions: @escaping @Sendable () -> String,
        catalogue: [any Tool],
        workTools: @escaping @Sendable () -> [any Tool],
        scopeResponseTokenCap: Int = 64
    ) {
        self.scopeInstructions = scopeInstructions
        self.workInstructions = workInstructions
        self.catalogue = catalogue
        self.workTools = workTools
        self.scopeResponseTokenCap = scopeResponseTokenCap
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
                    scopeInstructions() + "\n\n" + Self.renderedCatalogue(catalogue)
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
    /// selects from.
    private static func renderedCatalogue(_ tools: [any Tool]) -> String {
        "Task tools:\n" + tools
            .map { "- \($0.name): \($0.description)" }
            .joined(separator: "\n")
    }

    /// Parses a selection out of the scope step's text reply: every
    /// available tool name that appears in the text, in catalogue order.
    /// Substring match, case insensitive — robust to separators and to
    /// prose.
    public static func parseSelection(
        _ raw: String, from available: [String]
    ) -> [String] {
        let lowered = raw.lowercased()
        return available.filter { lowered.contains($0.lowercased()) }
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
public final class WorkTurnMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private let finishingNames: Set<String>
    private var callsInTurn = 0
    private var outputsInTurn = 0
    private var finishingOutputsInTurn = 0

    public init(finishingToolNames: some Sequence<String>) {
        self.finishingNames = Set(finishingToolNames)
    }

    /// Call from `onToolCall`. Starts a new turn when the previous one is
    /// fully executed.
    public func recordCall(_ call: Transcript.ToolCall) {
        lock.lock()
        defer { lock.unlock() }
        if outputsInTurn == callsInTurn {
            callsInTurn = 0
            outputsInTurn = 0
            finishingOutputsInTurn = 0
        }
        callsInTurn += 1
    }

    /// Call from `onToolOutput`. Returns `true` the moment the work is done
    /// — the turn is fully executed and performed at least one finishing
    /// action — i.e. the moment to throw `WorkflowStageComplete`.
    public func recordOutput(_ call: Transcript.ToolCall) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        outputsInTurn += 1
        if finishingNames.contains(call.toolName) {
            finishingOutputsInTurn += 1
        }
        return outputsInTurn == callsInTurn && finishingOutputsInTurn > 0
    }
}
