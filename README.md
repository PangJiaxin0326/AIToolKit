# AIToolKit

The tool-calling support package for Swift LLM apps. AIToolKit builds on
FoundationModels' official `Tool` protocol: tools travel as `[any Tool]` the
official way — into a `LanguageModelSession` — and AIToolKit adds the
assistive-tool tier and the staged workflow profile on top.

It has no third-party dependencies, is fully `Sendable`, and builds under
Swift 6 strict concurrency / language mode v6.

## What's inside

- `Tool` — FoundationModels' typed unit of work (`Arguments` / `Output`),
  re-exported, plus a `descriptor` for provider-facing export.
- `AssistiveTool` — the LLM-visible-only *unit request* tier of the tool
  split: an official `Tool` refined so its argument is one plain-text string
  (`TextArgument`), one integer (`IntegerArgument`), or nothing
  (`EmptyArguments`), and its output is one compact `String` of facts. Any
  tier of model can emit the call directly, and the schema costs a few
  tokens instead of ~100 — the context-budget lever for large tool sets on a
  32K-class window. Filter user-facing surfaces with `tool.isAssistive`
  (assistive tools are never user-visible).
- `WorkflowProfile` — ONE `LanguageModelSession.DynamicProfile` for the
  staged workflow: the `\.workflowStage` session property
  (`@SessionProperty`, host-flippable via `session.properties`) switches the
  body between the **gather** stage (fact collection; assistive tools only)
  and the **act** stage (request completion; user-visible finishing tools,
  local deictic state injected into the instructions).
  `WorkflowProfile.actStageHistory` is an optional history transform that
  drops gather-stage tool chatter.
- `ToolDescriptor` — provider-facing metadata (name, description, schemas)
  derivable from any official tool.
- `ViewTool` / `ViewToolRegistry` — view-producing tools the host renders
  (these keep a registry: a SwiftUI view cannot round-trip to the model).
- `GeneratedContent` helpers and typed errors (`ToolError`).

## The tool split

```swift
struct FindContact: AssistiveTool {
    typealias Arguments = TextArgument
    let name = "find_contact"
    let description = "Look up a contact. Input: a name fragment. Returns id + display name."
    func call(arguments: TextArgument) async throws -> String {
        // Return "no contact matches '…'" on a miss — never throw for that:
        // a thrown error fails the session turn; a fact lets the model adjust.
        "contactID: c_alex_chen — Alex Chen"
    }
}
```

Finishing tools are ordinary `@Generable`-argument `Tool`s — the semantically
complete actions a user could tap.

## The staged session

```swift
let profile = WorkflowProfile(
    gatherInstructions: { "Collect every fact the request needs…" },
    actInstructions: { "Complete the request now… \(localStateBlock)" },
    assistiveTools: tools.filter(\.isAssistive),
    finishingTools: tools.filter { !$0.isAssistive }
)
.model(myLanguageModel)
.temperature(0.2)

let session = LanguageModelSession(profile: profile)
let facts = try await session.respond(to: "User request: …\n\nGather the facts…")
session.properties.workflowStage = .act
let final = try await session.respond(to: "Now complete the user's request.")
```

The current recipe (prompt rails, parallel tool calls, the honest cost
model) lives in AIKit
[`AGENTS.md`](https://github.com/PangJiaxin0326/AIKit/blob/main/AGENTS.md) —
the single source of truth; this README only inventories the APIs.

## History

The previous paradigm — the lean-plan DAG (`WorkflowSpec` /
`WorkflowValidator` / `WorkflowExecutor`, the `WorkflowTool` session tool,
and the two-round planner/binder contract) — was removed in the profile
refactor. It survives at `9fd1ea6` and earlier, with its measured numbers
recorded in the experiment repo's `Findings.md` Parts IX–XVI.
[MIGRATION.md](MIGRATION.md) covers the older `ToolRegistry`-era migration
for codebases arriving from that generation.
