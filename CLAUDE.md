# AIToolKit — Working Notes

The tool-calling support package over FoundationModels' official `Tool`
protocol. `README.md` is the usage guide (including the select-then-work
recipe and its traps); this file is operational guidance.

## Build & test

```sh
swift build
swift test
```

Swift 6, strict concurrency, language mode v6. Depends only on
FoundationModels. Tests use Swift Testing (`import Testing`), never XCTest,
never the network. `WorkflowSessionProbeTests` exists to pin FM *runtime*
behavior the workflow relies on (hook ordering, history-transform
semantics) — if an OS update breaks an assumption, it fails there first.

## Layout

One target, seven files:

- `Tool.swift` — `Tool` typealias over the official protocol, `descriptor`,
  `ToolError`/`GenericToolError`, `ToolRegistryError`.
- `ToolDescriptor.swift` — provider-facing metadata from any official tool.
- `AssistiveTool.swift` — the unit-request tier (`TextArgument` /
  `IntegerArgument` / `EmptyArguments`, `isAssistive`).
- `WorkflowProfile.swift` — the select-then-work paradigm: `WorkflowStage`
  (`.scope`/`.work` via `@SessionProperty(\.workflowStage)`),
  `FinishingTool`, `ToolSelection`, `WorkflowProfile`, `WorkTurnMonitor`,
  `WorkflowStageComplete`.
- `ViewTool.swift` / `ViewToolRegistry.swift` — view-producing tools (main
  actor; the only registry left — views can't round-trip to the model).
- `FoundationModelsSupport.swift` — `GeneratedContent`/`GenerationSchema`
  sugar; the canonical helper layer (AIKit uses these, never duplicates).

## Conventions & verified facts

- Official-protocol-native: data tools are never registered or wrapped —
  they go to the session as `[any Tool]`. Ambient per-call state uses the
  official session-property system, not a custom context type.
- Every public type is `Sendable`; typed errors only.
- Verified on the OS 27 SDK (don't re-litigate, re-verify on SDK updates):
  - ALL of a parallel batch's `onToolCall`s fire before the first tool
    executes (`WorkTurnMonitor` depends on this).
  - On stage flip the runtime swaps the head instructions entry in place —
    history transforms must keep entry 0.
  - `toolCallingMode(.disallowed)` strips registered tools from the request
    (the scope stage renders the catalogue into instructions instead).
  - An error thrown from `onToolCall` (or inside a tool's `call`) surfaces
    wrapped in `LanguageModelSession.ToolCallError`; an `onToolOutput`
    throw propagates raw.
- Never trust training data for the OS 27 FM API; grep the SDK
  swiftinterface:
  `/Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks/FoundationModels.framework/Modules/FoundationModels.swiftmodule/arm64e-apple-macos.swiftinterface`

## History

Superseded paradigms live only in git history: the lean-plan DAG
(`9fd1ea6` and earlier) and the gather→act profile (the select-then-work
profile took over the `WorkflowProfile` name). Don't resurrect them from
stale docs.
