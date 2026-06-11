import Foundation
import FoundationModels

// MARK: - The scoped workflow profile (select the tools, then do the work)
//
// The inverse staging of `WorkflowProfile`. Where the gather→act workflow
// front-loads fact collection, the scoped workflow front-loads *tool
// selection*:
//
// - **scope** — the user intent plus the *finishing* (user-visible) tool
//   catalogue. The model's only job is to name the finishing tools the
//   request needs, through one `select_tools` call. The host aborts the turn
//   the moment that call arrives (a throwing `onToolCall` hook), so the step
//   costs exactly one LLM round and nothing executes.
// - **work** — the selected finishing tools plus only the assistive unit
//   requests *registered on them* (`ScopedFinishingTool`). All lookups and
//   all actions happen here. The user intent is re-sent; a cut-index
//   `historyTransform` drops every scope-step entry, so the catalogue and
//   the selection chatter never re-enter the context.
//
// The selection is the ONLY thing that crosses the stage boundary, and it
// crosses host-side (recorded in the `onToolCall` hook) — no model summary,
// no transcript carry-over.

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

/// The scope step's single signal: one text argument carrying the names of
/// the finishing tools the request needs. Its `call` never actually runs —
/// the host's `onToolCall` hook reads the argument and aborts the turn.
public struct SelectToolsTool: AssistiveTool {
    public typealias Arguments = TextArgument

    public static let toolName = "select_tools"
    public var name: String { Self.toolName }
    public let description = """
    Declare which task tools are needed to complete the user's request. \
    Input: the tool names as a comma-separated list, e.g. \
    "create_email_draft, schedule_event". Call exactly once, with every \
    tool the request requires — and call no other tool.
    """

    public init() {}

    public func call(arguments: TextArgument) async throws -> String {
        "tools selected"
    }
}

/// Sentinel thrown out of the scope step's `respond(...)` the moment
/// `select_tools` is called: the selection is recorded host-side and the
/// step needs no tool execution and no closing text turn.
public struct ScopeSelectionComplete: Error, Sendable {
    public init() {}
}

/// Thrown when the model calls a real tool during the scope step — the
/// throwing `onToolCall` hook fires before the tool executes, so the
/// premature action is blocked, not performed. Hosts recover with one
/// corrective respond.
public struct ScopeStepViolation: Error, Sendable {
    public let toolName: String
    public init(toolName: String) {
        self.toolName = toolName
    }
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

    /// - Parameters:
    ///   - scopeInstructions: Scope-step instructions (select, don't act).
    ///   - workInstructions: Work-step instructions, evaluated per request —
    ///     inject local deictic state here.
    ///   - catalogue: The full finishing-tool catalogue plus
    ///     `SelectToolsTool` — what the scope step sees.
    ///   - workTools: The work step's tool set, evaluated per request: the
    ///     selected finishing tools, their registered assistive tools, and
    ///     `TaskCompleteTool`.
    public init(
        scopeInstructions: @escaping @Sendable () -> String,
        workInstructions: @escaping @Sendable () -> String,
        catalogue: [any Tool],
        workTools: @escaping @Sendable () -> [any Tool]
    ) {
        self.scopeInstructions = scopeInstructions
        self.workInstructions = workInstructions
        self.catalogue = catalogue
        self.workTools = workTools
    }

    public var body: some LanguageModelSession.DynamicProfile {
        if stage == .scope {
            LanguageModelSession.Profile {
                Instructions(scopeInstructions())
                catalogue
            }
        } else {
            LanguageModelSession.Profile {
                Instructions(workInstructions())
                workTools()
            }
        }
    }

    /// Parses a selection out of the model's `select_tools` argument (or, as
    /// a fallback, out of a prose answer): every available tool name that
    /// appears in the text, in catalogue order. Substring match, case
    /// insensitive — robust to separators and to prose.
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
