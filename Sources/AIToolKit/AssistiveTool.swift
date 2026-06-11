import Foundation
import FoundationModels

// MARK: - Assistive tools (LLM-visible-only unit requests)
//
// The toolkit distinguishes two kinds of official `FoundationModels.Tool`:
//
// - **Task-finishing tools** — semantically complete user actions (send the
//   message, schedule the event). These are the *user-visible* tool set: a
//   host surfaces them in UI, and they are what a workflow ultimately exists
//   to call.
// - **Assistive tools** — LLM-visible-only *unit requests* the model uses to
//   gather what the finishing call needs: resolve a name to an id, look up a
//   document, compute a size. They never appear in user-facing UI.
//
// An assistive tool is deliberately austere: its argument is one plain-text
// string, one integer, or nothing — a shape any tier of model can emit
// directly with no structured authoring (and therefore nothing to repair),
// and whose schema costs a few tokens instead of ~100. That austerity is the
// context-budget lever: a gather stage exposing only assistive tools fits a
// large tool *count* into a small manifest.

/// The argument shapes an `AssistiveTool` may take. Closed set by design:
/// conformances are `EmptyArguments`, `TextArgument`, and `IntegerArgument`.
public protocol AssistiveArguments: ConvertibleFromGeneratedContent, Sendable {}

/// An assistive tool that takes no input at all.
@Generable
public struct EmptyArguments: AssistiveArguments {
    public init() {}
}

/// An assistive tool's single plain-text input. What the text *means* (a
/// contact name, a search query, a date hint) is the tool description's job —
/// by design the argument carries minimal information.
@Generable
public struct TextArgument: AssistiveArguments {
    @Guide(description: "The single plain-text input for this request.")
    public var value: String

    public init(value: String) {
        self.value = value
    }
}

/// An assistive tool's single integer input.
@Generable
public struct IntegerArgument: AssistiveArguments {
    @Guide(description: "The single integer input for this request.")
    public var value: Int

    public init(value: Int) {
        self.value = value
    }
}

/// An LLM-visible-only unit-request tool: one scalar argument (or none) in,
/// one plain string out.
///
/// `AssistiveTool` is an ordinary `FoundationModels.Tool` — hand it to a
/// `LanguageModelSession` like any other — refined by two compile-time
/// constraints:
///
/// - `Arguments` is one of the `AssistiveArguments` shapes (`TextArgument`,
///   `IntegerArgument`, `EmptyArguments`), so the model can always generate
///   the call directly;
/// - `Output == String`, so the result rides back into the transcript as a
///   compact fact, not a payload.
///
/// Hosts must NOT surface assistive tools in user-facing UI; only
/// task-finishing tools are user-visible. `isAssistive` on `Tool` is the
/// filter.
public protocol AssistiveTool: Tool where Arguments: AssistiveArguments, Output == String {}

extension Tool {
    /// Whether this tool is an LLM-visible-only assistive unit request (and
    /// must therefore be excluded from user-facing tool surfaces).
    public var isAssistive: Bool { self is any AssistiveTool }
}
