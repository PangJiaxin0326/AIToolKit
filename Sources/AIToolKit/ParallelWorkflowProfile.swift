import Foundation
import FoundationModels

// MARK: - The parallel workflow (propose a set, then build each in its own session)
//
// The fan-out sibling of `ProgressiveWorkflowProfile`. Where the progressive
// profile plans once and then builds the components SEQUENTIALLY in one session
// (host-stopping after each), this pattern builds them in PARALLEL: the host
// runs one session PER component, each exposing exactly that component's tool
// with tool calling `.required`, and host-stops it the instant its tool fires.
//
//   propose → [ build₀ | build₁ | build₂ | … ]   (all at once)
//
// The latency of N sequential builds is the SUM of their turn latencies; in
// parallel it is the MAX. The primitive each parallel session uses is
// `ForcedToolProfile` — one tool, forced, host-stopped — driven by
// `runForcedToolTurn`. The proposal step is itself a `ForcedToolProfile` over a
// single "propose" tool, so the whole workflow needs no guided generation and
// runs on every tier (function schemas, never `response_format`).

/// One profile that exposes a fixed tool set and FORCES a call (`tool_choice:
/// required` on an OpenAI-style wire), so the model emits a call with no prose
/// preamble. Pair it with `runForcedToolTurn`, which host-stops the session the
/// instant the tool's output lands (so the forced mode never loops).
public struct ForcedToolProfile: LanguageModelSession.DynamicProfile {
    private let instructions: @Sendable () -> String
    private let tools: [any Tool]

    /// - Parameters:
    ///   - instructions: The step instructions, evaluated per request.
    ///   - tools: The tool(s) to expose and force — normally exactly one.
    public init(
        instructions: @escaping @Sendable () -> String,
        tools: [any Tool]
    ) {
        self.instructions = instructions
        self.tools = tools
    }

    public var body: some LanguageModelSession.DynamicProfile {
        LanguageModelSession.Profile {
            Instructions(instructions())
            tools
        }
        .toolCallingMode(.required)
    }
}

/// The outcome of one forced-tool turn: how long it took and, if it failed, a
/// short description. A turn that produced its forced tool call (then was
/// host-stopped) reports `failure == nil`; the *result* of the call is observed
/// through the tool's own side effect (a stage/sink the host owns), not here.
public struct ForcedToolOutcome: Sendable {
    public let duration: Duration
    public let failure: String?

    public init(duration: Duration, failure: String?) {
        self.duration = duration
        self.failure = failure
    }

    public var succeeded: Bool { failure == nil }
}

/// Drive one `ForcedToolProfile` session to its single tool call, host-stopping
/// the moment the tool's output lands (`WorkflowStageComplete`), so no closing
/// text turn is billed. This is the unit a parallel fan-out dispatches N of, one
/// per proposed component, concurrently.
///
/// Provider-agnostic: generic over any `LanguageModel`. Nonisolated like the
/// other workflow runners — the session machinery runs off the main actor.
public func runForcedToolTurn<Model: LanguageModel>(
    instructions: @escaping @Sendable () -> String,
    tools: [any Tool],
    prompt: String,
    model: Model,
    temperature: Double = 0.2
) async -> ForcedToolOutcome {
    let profile = ForcedToolProfile(instructions: instructions, tools: tools)
        .model(model)
        .temperature(temperature)
        // End the step the instant the forced tool lands — the "disable when done".
        .onToolOutput { _, _ in throw WorkflowStageComplete() }
        .transcriptErrorHandlingPolicy(.preserveTranscript)

    let session = LanguageModelSession(profile: profile)
    let started = ContinuousClock.now
    var failure: String?
    do {
        _ = try await session.respond(to: prompt).content
        failure = "The model completed without producing a forced tool output."
    } catch {
        let unwrapped = (error as? LanguageModelSession.ToolCallError)?.underlyingError ?? error
        if !(unwrapped is WorkflowStageComplete) {
            failure = Self_describeForcedToolError(error)
        }
    }
    return ForcedToolOutcome(duration: ContinuousClock.now - started, failure: failure)
}

/// A compact description of a forced-turn failure, calling out rate limiting
/// (firing several builds at once can trip a provider's throttle) and timeouts.
private func Self_describeForcedToolError(_ error: any Error) -> String {
    if let llmError = error as? LanguageModelError {
        switch llmError {
        case .rateLimited: return "rate-limited"
        case .timeout: return "timeout"
        default: return "\(llmError)"
        }
    }
    return "\(error)"
}
