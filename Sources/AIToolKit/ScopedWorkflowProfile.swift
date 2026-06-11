import Foundation
import FoundationModels

// MARK: - The scoped workflow profile (select the tools, then do the work)
//
// The inverse staging of `WorkflowProfile`. Where the gather→act workflow
// front-loads fact collection, the scoped workflow front-loads *tool
// selection*:
//
// - **scope** — the user intent plus the *finishing* (user-visible) tool
//   catalogue, with tool calling DISALLOWED (`tool_choice: none` on an
//   OpenAI-style wire): the manifests are visible but nothing can execute,
//   and the model answers in plain text with the needed tool names — a
//   handful of output tokens, where even a minimal tool-call envelope
//   costs ~30+. One LLM round, ended by its own short text turn; the host
//   parses the names with `parseSelection`.
// - **work** — the selected finishing tools plus only the assistive unit
//   requests *registered on them* (`ScopedFinishingTool`). All lookups and
//   all actions happen here. The user intent is re-sent; a cut-index
//   `historyTransform` drops every scope-step entry, so the catalogue and
//   the selection chatter never re-enter the context. The host ends the
//   step in code via `WorkTurnMonitor` the moment a fully-executed turn
//   contains a finishing output.
//
// The selection is the ONLY thing that crosses the stage boundary, and it
// crosses host-side — no model summary, no transcript carry-over.

/// Which step of the scoped workflow the session is in.
public enum ScopedWorkflowStage: String, Sendable, Hashable, CaseIterable {
    /// Name the finishing tools the request needs (nothing executes).
    case scope
    /// Do all the work: scoped assistive lookups, then the selected actions.
    case work
}

public struct ScopedWorkflowStageKey: SessionPropertyKey {
    public static var defaultValue: ScopedWorkflowStage { .scope }
}

extension SessionPropertyValues {
    /// The scoped-workflow step of this session. Hosts flip it to `.work`
    /// after the scope step's selection lands.
    public var scopedWorkflowStage: ScopedWorkflowStage {
        get { self[ScopedWorkflowStageKey.self] }
        set { self[ScopedWorkflowStageKey.self] = newValue }
    }
}

/// A user-visible finishing tool that registers the assistive unit requests
/// needed to resolve its arguments. The scope step selects finishing tools;
/// the work step exposes only the union of the selected tools' registrations
/// — assistive scoping is derived from the selection, never from the task.
public protocol ScopedFinishingTool: Tool {
    var registeredAssistiveTools: [any Tool] { get }
}

/// The scoped workflow profile. Stage-switched like `WorkflowProfile`; the
/// work step's tool set is produced per request by a closure, because it is
/// derived from the scope step's runtime selection.
public struct ScopedWorkflowProfile: LanguageModelSession.DynamicProfile {
    @SessionProperty(\.scopedWorkflowStage) private var stage

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
