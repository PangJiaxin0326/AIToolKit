# AIToolKit

The tool-calling support package for Swift LLM apps. AIToolKit builds on
FoundationModels' official `Tool` protocol: tools travel as `[any Tool]` the
official way — into a `LanguageModelSession` — and AIToolKit adds the workflow
layer that lets a model compose them into locally-executed DAGs.

It has no third-party dependencies, is fully `Sendable`, and builds under
Swift 6 strict concurrency / language mode v6.

## What's inside

- `Tool` — FoundationModels' typed unit of work (`Arguments` / `Output`),
  re-exported, plus a `descriptor` for provider-facing export.
- `WorkflowTool` — **the** model-facing workflow contract: one official tool
  whose arguments schema is the other tools and their relationships.
- `ToolDescriptor` — provider-facing metadata (name, description, schemas)
  derivable from any official tool.
- `WorkflowSpec` / `WorkflowValidator` / `WorkflowExecutor` — the workflow IR
  and the topological, parallel-where-safe execution engine.
- `WorkflowTwoRound*` — the two-round plan/harvest/bind wire models, pure
  compiler, schema and prompt assets, and plan cache, for hosts that run the
  protocol as two isolated LLM requests.
- `ViewTool` / `ViewToolRegistry` — view-producing tools the host renders
  (these keep a registry: a SwiftUI view cannot round-trip to the model).
- `GeneratedContent` helpers and typed errors (`ToolError`, `WorkflowError`).

## Installation

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/PangJiaxin0326/AIToolKit.git", branch: "main"),
]
```

Then add `AIToolKit` to your target's dependencies:

```swift
.target(
    name: "MyTarget",
    dependencies: [
        .product(name: "AIToolKit", package: "AIToolKit"),
    ]
)
```

## Usage

Define tools with the official protocol:

```swift
import AIToolKit
import FoundationModels

struct EchoTool: Tool {
    @Generable
    struct Arguments { var text: String }

    @Generable
    struct Output { var echoed: String }

    let name = "echo"
    let description = "Echoes input back."

    func call(arguments: Arguments) async throws -> Output {
        Output(echoed: arguments.text)
    }
}
```

Tools can be called directly with `try await tool(arguments)`, passed straight
to a `LanguageModelSession(tools:)`, or composed into workflows:

```swift
let workflow = WorkflowTool(
    tools: [FindContactTool(), SendMessageTool()],
    harvester: AppContextHarvester(),               // optional: local-context slots
    sources: ["current_contact", "foreground_document"]
)
let session = LanguageModelSession(tools: [workflow]) {
    Instructions(workflow.instructions())
}
let response = try await session.respond(to: "Tell Bob the meeting moved to 3pm")
```

## The unified workflow tool

`WorkflowTool` collapses what used to be two separate layers into one
contract. The model emits one DAG of `{id, tool, input}` nodes; data edges are
`$ref` JSON Pointers into earlier node outputs; values that live in local or
private state are `$slot` holes declared in `context_slots`. One
`call(arguments:)` covers every path:

- **Self-contained plan** → validated and executed locally in one call.
- **Deterministic slots** → harvested and auto-bound; still one call.
- **Ambiguous slots** → the tool replies `needs_binding` with candidate ids
  and labels (never values); the model calls the same tool again with
  `$bind` markers. The binding round rides the ordinary session tool loop —
  no bespoke runner.

Hosts that need strict round isolation (planner and binder as separate LLM
requests), a native candidate-picker between rounds, or `WorkflowPlanCache`
planner-skipping keep driving the pure `WorkflowTwoRoundCompiler` from their
own runner (AIKit's `WorkflowTwoRoundRunner`); both paths share every
validation and execution stage.

Migrating from `ToolRegistry` / `WorkflowSchema` / the synthetic
`workflow_run` descriptor? See [MIGRATION.md](MIGRATION.md).

The current developer guidance and reproduction recipe live in AIKit
[`AGENTS.md`](https://github.com/PangJiaxin0326/AIKit/blob/main/AGENTS.md). This
README only inventories AIToolKit APIs so the recommendations stay in one place.
The legacy workflow guide files in this package are forwarding pages to that
source of truth.
