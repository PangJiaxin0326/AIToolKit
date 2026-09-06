import Foundation
import FoundationModels

// MARK: - The progressive workflow (plan once, then build one component per step)
//
// The streaming sibling of `WorkflowProfile`. Where the plain workflow's work
// step does everything in one turn and host-stops on the first finishing
// output, this one front-loads a PLAN and then executes it ONE finishing tool
// at a time, host-stopping after each — so the host can render each component
// the moment its step lands, instead of making the user wait for the whole UI.
//
// - **plan** (step 1) — the user intent plus the finishing-tool catalogue
//   rendered into the instructions, tool calling DISALLOWED. The model answers
//   with an ORDERED list of finishing-tool names (reuse `ToolSelection`,
//   parsed host-side preserving the model's order): the build order of the
//   composite. One LLM round; the host has the plan — and can show a skeleton —
//   before a single component is built.
// - **build** (steps 2…N) — one step per planned component. The session
//   property `progressiveStep` selects which component this step builds; the
//   profile exposes ONLY that component's finishing tool with tool calling
//   `.required` (the model must build it, no prose). The host stops the step
//   the moment that component's finishing output lands (`WorkflowStageComplete`),
//   renders it, advances the step, and re-prompts — streaming the UI in.
//
// Nothing crosses a step boundary in-band: the host cuts history per step and
// re-states the running context (intent, plan, what's already placed) in the
// step instructions, so each build stays a small, cheap turn.

/// Which phase of the progressive workflow the session is in.
public enum ProgressiveStage: String, Sendable, Hashable, CaseIterable {
    /// Choose the ordered list of components to build (nothing executes).
    case plan
    /// Build the single component named by `progressiveStep`.
    case build
}

extension SessionPropertyValues {
    /// The progressive workflow's phase. Hosts flip it to `.build` after the
    /// plan lands.
    @SessionPropertyEntry public var progressiveStage: ProgressiveStage = .plan

    /// The zero-based index of the component the current build step constructs.
    /// Hosts increment it as they advance through the plan.
    @SessionPropertyEntry public var progressiveStep: Int = 0
}

@available(*, deprecated, message: "progressiveStage is declared with @SessionPropertyEntry; read and write `SessionPropertyValues.progressiveStage` directly. Raw subscripts through this key use separate storage and no longer reach it.")
public struct ProgressiveStageKey: SessionPropertyKey {
    public static var defaultValue: ProgressiveStage { .plan }
}

@available(*, deprecated, message: "progressiveStep is declared with @SessionPropertyEntry; read and write `SessionPropertyValues.progressiveStep` directly. Raw subscripts through this key use separate storage and no longer reach it.")
public struct ProgressiveStepKey: SessionPropertyKey {
    public static var defaultValue: Int { 0 }
}

/// The progressive profile. Stage-switched on a session property like
/// `WorkflowProfile`, but the build stage is additionally parameterized by
/// `progressiveStep`: its instructions and its (single) exposed tool are a
/// function of which component the host is currently building.
public struct ProgressiveWorkflowProfile: LanguageModelSession.DynamicProfile {
    @SessionProperty(\.progressiveStage) private var stage
    @SessionProperty(\.progressiveStep) private var step

    private let planInstructions: @Sendable () -> String
    private let stepInstructions: @Sendable (Int) -> String
    private let catalogue: [any Tool]
    private let stepTools: @Sendable (Int) -> [any Tool]
    private let planResponseTokenCap: Int

    /// - Parameters:
    ///   - planInstructions: Plan-step instructions (list the components, in
    ///     build order, nothing else).
    ///   - stepInstructions: Build-step instructions, evaluated per step index
    ///     — inject the running context (intent, plan, what's already placed).
    ///   - catalogue: The full finishing-tool catalogue the plan step sees
    ///     (visible, not callable).
    ///   - stepTools: The tool(s) exposed for a given build step — normally the
    ///     single finishing tool that builds that step's component.
    ///   - planResponseTokenCap: Output budget for the plan reply (an ordered
    ///     list of a few names).
    public init(
        planInstructions: @escaping @Sendable () -> String,
        stepInstructions: @escaping @Sendable (Int) -> String,
        catalogue: [any Tool],
        stepTools: @escaping @Sendable (Int) -> [any Tool],
        planResponseTokenCap: Int = 64
    ) {
        self.planInstructions = planInstructions
        self.stepInstructions = stepInstructions
        self.catalogue = catalogue
        self.stepTools = stepTools
        self.planResponseTokenCap = planResponseTokenCap
    }

    public var body: some LanguageModelSession.DynamicProfile {
        if stage == .plan {
            // Manifests visible, calls impossible: the model answers in text
            // with the ordered component list. The catalogue is rendered INTO
            // the instructions (the runtime strips registered tools when tool
            // calling is disallowed).
            LanguageModelSession.Profile {
                Instructions(
                    planInstructions() + "\n\n" + Self.renderedCatalogue(catalogue)
                )
            }
            .toolCallingMode(.disallowed)
            .maximumResponseTokens(planResponseTokenCap)
        } else {
            // One component, forced: only this step's tool is exposed, and
            // `.required` makes the model build it with no prose preamble. The
            // host stops the step on the finishing output.
            LanguageModelSession.Profile {
                Instructions(stepInstructions(step))
                stepTools(step)
            }
            .toolCallingMode(.required)
        }
    }

    /// The plan step's catalogue as instruction text — name and description per
    /// finishing tool, the components the plan is assembled from.
    private static func renderedCatalogue(_ tools: [any Tool]) -> String {
        "Components you can place:\n" + tools
            .map { "- \($0.name): \($0.description)" }
            .joined(separator: "\n")
    }
}
