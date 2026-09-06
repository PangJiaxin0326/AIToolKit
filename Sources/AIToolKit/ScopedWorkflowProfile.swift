import Foundation
import FoundationModels

// MARK: - Scoped workflow (scope → work → done, in one `respond`)
//
// A three-stage variant of `WorkflowProfile` that collapses scope+work+done into
// a SINGLE `respond` driven by stage flips inside the profile's tool hooks:
//
//   • **scope** — only `ScopingTool` (and `AskTool`) are exposed, with
//     `.toolCallingMode(.required)`. The model makes ONE tool call: a route
//     (`{action}`) captured host-side. Host-side planning then binds the work
//     tool for the next round-trip — no LLM call.
//   • **work** — the bound finishing tool plus `AskTool`, also `.required`. The
//     model makes ONE more tool call: the bound action, or `askUser` when it
//     cannot proceed without clarification.
//   • **done** — no tools, `.disallowed`, response capped tight. A trivial
//     closing round-trip ("ok") so the session loop terminates naturally
//     instead of via a thrown sentinel. Latency-trivial — the work is already
//     done before this round-trip runs.
//
// History reset per stage: the `historyTransform` keeps each stage's own
// instructions + (for scope/work) the user prompt and DROPS the cross-stage
// tool chatter, so every round-trip sees only the context it needs.

/// Thrown from `onToolOutput` to end a `ScopedWorkflowProfile.respond` once
/// the workflow is done — so the session doesn't issue the trailing "ok"
/// round-trip that the (now-optional) `.done` stage would otherwise carry.
/// Pair with `.transcriptErrorHandlingPolicy(.preserveTranscript)`.
public struct ScopedWorkflowComplete: Error, Sendable {
    public init() {}
}

/// Which step of the scoped workflow the session is in.
public enum ScopedWorkflowStage: String, Sendable, Hashable, CaseIterable {
    /// Pick the action via `ScopingTool` (or refuse via `AskTool`).
    case scope
    /// Perform the bound action via its finishing tool (or ask).
    case work
    /// Close the protocol with a tiny acknowledgement.
    case done
}

extension SessionPropertyValues {
    /// The scoped workflow's current step. Hosts flip it from `.onToolOutput`.
    @SessionPropertyEntry public var scopedWorkflowStage: ScopedWorkflowStage = .scope
}

@available(*, deprecated, message: "scopedWorkflowStage is declared with @SessionPropertyEntry; read and write `SessionPropertyValues.scopedWorkflowStage` directly. Raw subscripts through this key use separate storage and no longer reach it.")
public struct ScopedWorkflowStageKey: SessionPropertyKey {
    public static var defaultValue: ScopedWorkflowStage { .scope }
}

// MARK: - ScopingTool: the one tool exposed in scope

/// The scope step's single carriage: pick one of the listed action names. The
/// catalogue lives in the scope instructions; this tool's only job is to
/// transport the chosen name back to the host (`receive`) and let the tool-call
/// lifecycle drive the stage flip in `onToolOutput`.
@Generable
public struct ScopeRequest: Sendable {
    @Guide(description: "The name of the action you choose to perform, EXACTLY as written in the available-actions list — no aliases, no decoration.")
    public var action: String

    public init(action: String) {
        self.action = action
    }
}

public struct ScopingTool: Tool {
    public typealias Arguments = ScopeRequest
    public typealias Output = String

    public static let toolName = "scope"
    public var name: String { Self.toolName }
    public let description: String
    private let receive: @Sendable (String) -> Void

    /// - Parameters:
    ///   - description: A short summary the model sees when reading this tool's
    ///     manifest (the catalogue of action names rides in the instructions).
    ///   - receive: Host-side sink for the chosen action name; called from the
    ///     tool's `call` before the result lands and `onToolOutput` fires.
    public init(
        description: String = "Pick the action that matches the user's request. Call this once.",
        receive: @escaping @Sendable (String) -> Void
    ) {
        self.description = description
        self.receive = receive
    }

    public func call(arguments: ScopeRequest) async throws -> String {
        receive(arguments.action.trimmingCharacters(in: .whitespacesAndNewlines))
        return "scoped"
    }
}

// MARK: - AskTool: the escape valve in scope and work

/// Available alongside `ScopingTool` (scope) and the bound finishing tool
/// (work) so the model has a structured way to stop and ask the user one
/// clarifying question when it genuinely cannot proceed.
@Generable
public struct AskRequest: Sendable {
    @Guide(description: "A single short question for the user — the one piece of information you cannot proceed without.")
    public var question: String

    public init(question: String) {
        self.question = question
    }
}

public struct AskTool: Tool {
    public typealias Arguments = AskRequest
    public typealias Output = String

    public static let toolName = "askUser"
    public var name: String { Self.toolName }
    public let description = """
    Ask the user ONE short clarifying question — only when you cannot proceed \
    without information that is not in your instructions or the foreground \
    context. If you can act with what you have, do that instead.
    """
    private let receive: @Sendable (String) -> Void

    public init(receive: @escaping @Sendable (String) -> Void) {
        self.receive = receive
    }

    public func call(arguments: AskRequest) async throws -> String {
        receive(arguments.question.trimmingCharacters(in: .whitespacesAndNewlines))
        return "asked"
    }
}

// MARK: - Profile

/// The scoped workflow's profile. Stage-switched via a host-owned closure (NOT
/// a session property) so the runner's `onToolOutput` hook can flip the stage
/// without needing the session reference — the body just calls `currentStage()`
/// on each re-render to see the current value.
public struct ScopedWorkflowProfile: LanguageModelSession.DynamicProfile {
    private let currentStage: @Sendable () -> ScopedWorkflowStage
    private let scopeInstructions: @Sendable () -> String
    private let scopingTool: ScopingTool
    private let askTool: AskTool
    private let workInstructions: @Sendable () -> String
    private let workTools: @Sendable () -> [any Tool]
    private let doneInstructions: @Sendable () -> String
    private let doneTokenCap: Int

    /// - Parameters:
    ///   - currentStage: Returns the current stage on each profile re-render.
    ///     The runner backs this with its own thread-safe stage holder and
    ///     mutates it from the `onToolOutput` hook — so the next round-trip
    ///     within the same `respond` sees the new stage.
    ///   - scopeInstructions: Rendered per scope round-trip — the available
    ///     actions list (name + description) plus the foreground context.
    ///   - scopingTool: The route-capture tool exposed in scope.
    ///   - askTool: The clarify-with-the-user tool exposed in scope AND work.
    ///   - workInstructions: Rendered per work round-trip — the bound action's
    ///     description, the user's request, and the foreground context. The
    ///     host fills this in after scope's `onToolOutput`.
    ///   - workTools: The work step's tool set — the bound finishing tool plus
    ///     `askTool`. Evaluated per request.
    ///   - doneInstructions: The closing round-trip's brief — defaults to a
    ///     one-token "ok".
    ///   - doneTokenCap: Output budget for the closing reply (default 8 — the
    ///     model's "ok" only needs a few).
    public init(
        currentStage: @escaping @Sendable () -> ScopedWorkflowStage,
        scopeInstructions: @escaping @Sendable () -> String,
        scopingTool: ScopingTool,
        askTool: AskTool,
        workInstructions: @escaping @Sendable () -> String,
        workTools: @escaping @Sendable () -> [any Tool],
        doneInstructions: @escaping @Sendable () -> String = { "The action is complete. Reply with just: ok" },
        doneTokenCap: Int = 8
    ) {
        self.currentStage = currentStage
        self.scopeInstructions = scopeInstructions
        self.scopingTool = scopingTool
        self.askTool = askTool
        self.workInstructions = workInstructions
        self.workTools = workTools
        self.doneInstructions = doneInstructions
        self.doneTokenCap = doneTokenCap
    }

    public var body: some LanguageModelSession.DynamicProfile {
        let stage = currentStage()
        // Chained if/else (not switch) because the result builder reconciles
        // branches via `buildEither` — the same pattern `WorkflowProfile` uses.
        if stage == .scope {
            // Scope exposes ONLY `ScopingTool` — no AskTool, no catalogue.
            // `.required` makes the model call it; if the request doesn't fit
            // any action the host refuses (no clarification round-trip here).
            LanguageModelSession.Profile {
                Instructions(scopeInstructions())
                scopingTool
            }
            .toolCallingMode(.required)
        } else if stage == .work {
            // Work mandates a tool call too: the bound action, or AskTool when
            // the model cannot fill its arguments.
            LanguageModelSession.Profile {
                Instructions(workInstructions())
                workTools()
            }
            .toolCallingMode(.required)
        } else {
            // .done — no tools, no prompt (see the transform). The model just
            // closes the loop with a tiny acknowledgement.
            LanguageModelSession.Profile {
                Instructions(doneInstructions())
            }
            .toolCallingMode(.disallowed)
            .maximumResponseTokens(doneTokenCap)
        }
    }

    /// The per-stage history transform: each stage's round-trip sees only its
    /// own instructions (the runtime swaps the head in place per request) and,
    /// for stages that act on the user's request, the user prompt. Tool chatter
    /// from earlier stages is dropped — the host has baked the needed state
    /// into the next stage's instructions.
    public static func resetHistory(
        _ entries: [Transcript.Entry], stage: ScopedWorkflowStage
    ) -> [Transcript.Entry] {
        entries.compactMap { entry in
            switch entry {
            case .instructions:
                // The runtime renders the current stage's instructions in
                // place, so keeping the head instructions is correct (and
                // dropping it would leave the model with no system message).
                return entry
            case .prompt:
                // The closing stage answers "ok"; the user's prompt would only
                // tempt it to keep working.
                return stage == .done ? nil : entry
            case .toolCalls, .toolOutput, .response, .reasoning:
                // Cross-stage chatter is intentionally dropped: each stage is
                // single round-trip and is fed its needed state via the
                // instructions the host renders.
                return nil
            @unknown default:
                // Unknown future entries stay out by default.
                return nil
            }
        }
    }
}
