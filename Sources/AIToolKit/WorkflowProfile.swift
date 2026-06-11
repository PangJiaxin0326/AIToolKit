import Foundation
import FoundationModels

// MARK: - The workflow profile (one DynamicProfile, staged by a session flag)
//
// The workflow paradigm on the OS 27 FoundationModels surface: ONE
// `LanguageModelSession.DynamicProfile` whose body switches on a session
// state flag. There is no bespoke planner/executor pipeline — the session IS
// the orchestrator; the profile only decides what each stage of it sees:
//
// - **gather** — instructions for fact collection plus the *assistive* tool
//   set (LLM-visible-only unit requests with scalar arguments — see
//   `AssistiveTool`). The manifest is tiny by construction, so this stage
//   fits a 32K-class on-device/PCC window even with many tools.
// - **act** — instructions for completing the request plus the *finishing*
//   (user-visible) tool set. Act-stage instructions are produced per request
//   by a closure, so the host can inject freshly gathered facts or local
//   deictic context (the open document, the current selection) without any
//   LLM involvement.
//
// The flag lives in `SessionPropertyValues` (`\.workflowStage`), so the host
// flips it between `respond(...)` calls — and a tool could read or advance it
// via `@SessionProperty` as well. `historyTransform(forActStage:)` is the
// context diet between stages: gather-stage tool chatter is dropped before
// the act stage re-sends the transcript.

/// Which stage of the workflow the session is in. The session-scoped state
/// flag the profile body branches on.
public enum WorkflowStage: String, Sendable, Hashable, CaseIterable {
    /// Collect the facts the request needs, through assistive tools.
    case gather
    /// Complete the request, through the user-visible finishing tools.
    case act
}

public struct WorkflowStageKey: SessionPropertyKey {
    public static var defaultValue: WorkflowStage { .gather }
}

extension SessionPropertyValues {
    /// The workflow stage of this session. Hosts flip it to `.act` after the
    /// gather response; tools may read (or advance) it via `@SessionProperty`.
    public var workflowStage: WorkflowStage {
        get { self[WorkflowStageKey.self] }
        set { self[WorkflowStageKey.self] = newValue }
    }
}

/// The single workflow profile. Apply session-wide knobs as modifiers at the
/// construction site (`WorkflowProfile(...).model(...).temperature(0.2)`).
public struct WorkflowProfile: LanguageModelSession.DynamicProfile {
    @SessionProperty(\.workflowStage) private var stage

    private let gatherInstructions: @Sendable () -> String
    private let actInstructions: @Sendable () -> String
    private let assistiveTools: [any Tool]
    private let finishingTools: [any Tool]

    /// - Parameters:
    ///   - gatherInstructions: Gather-stage instructions, evaluated per
    ///     request.
    ///   - actInstructions: Act-stage instructions, evaluated per request —
    ///     inject gathered facts or local deictic context here.
    ///   - assistiveTools: The LLM-visible-only unit-request tools
    ///     (`AssistiveTool` conformers) for the gather stage.
    ///   - finishingTools: The user-visible task-finishing tools for the act
    ///     stage.
    public init(
        gatherInstructions: @escaping @Sendable () -> String,
        actInstructions: @escaping @Sendable () -> String,
        assistiveTools: [any Tool],
        finishingTools: [any Tool]
    ) {
        self.gatherInstructions = gatherInstructions
        self.actInstructions = actInstructions
        self.assistiveTools = assistiveTools
        self.finishingTools = finishingTools
    }

    public var body: some LanguageModelSession.DynamicProfile {
        if stage == .gather {
            LanguageModelSession.Profile {
                Instructions(gatherInstructions())
                assistiveTools
            }
        } else {
            LanguageModelSession.Profile {
                Instructions(actInstructions())
                finishingTools
            }
        }
    }

    /// The between-stages context diet: drops gather-stage tool calls and
    /// tool outputs from the transcript once the session is in the act stage,
    /// keeping only prompts and responses (the model's own gather summary
    /// carries the facts forward). Attach with
    /// `.historyTransform(WorkflowProfile.actStageHistory)`.
    public static func actStageHistory(
        _ entries: [Transcript.Entry]
    ) -> [Transcript.Entry] {
        entries.filter { entry in
            switch entry {
            case .toolCalls, .toolOutput:
                return false
            default:
                return true
            }
        }
    }
}
