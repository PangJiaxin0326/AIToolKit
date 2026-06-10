# AIToolKit

The tool-calling support package for Swift LLM apps. AIToolKit builds on
FoundationModels' official `Tool` protocol and provides a process-wide
`ToolRegistry` so Swift packages can ship tools an LLM can call.

It has no third-party dependencies, is fully `Sendable`, and builds under
Swift 6 strict concurrency / language mode v6.

## What's inside

- `Tool` — FoundationModels' typed unit of work (`Arguments` / `Output`).
- `ToolContext` — small ambient state used by workflow and view-tool dispatch.
- `ToolRegistry` — an actor that registers, subsets, and dispatches tools by name.
- `ToolDescriptor` — provider-facing metadata backed by `GenerationSchema`.
- `GeneratedContent` — FoundationModels' local content value for arguments,
  outputs, workflow inputs, and workflow results.
- `ToolError` / `ToolRegistryError` — typed errors with retriability.

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

let registry = ToolRegistry()
await registry.register(EchoTool())
```

Tools can also be called directly with `try await tool(arguments)`.

## Workflows and two-round-trip APIs

AIToolKit also ships a one-shot **workflow** layer — the model emits one
`WorkflowSpec` (a DAG of tool calls wired by `$ref` JSON Pointers) and the device
validates and executes it locally without re-calling the model:

- `WorkflowSpec` / `WorkflowNode` — the lean IR (`{id, tool, input}` per node;
  every other field defaults).
- `WorkflowValidator` — graph shape, tool availability, JSON Pointer syntax, and limit checks.
- `WorkflowExecutor` — topological, parallel-where-safe execution via `ToolRegistry`.
- `WorkflowReferenceResolver` — resolves `$ref`/`$literal` values (node, context, user_input).
- `WorkflowSchema` / `WorkflowPromptBuilder` — strict schemas + planning prompts.

For tasks whose parameters depend on local/private state, a **two-round-trip**
layer (Plan → local context harvest → Bind) builds on the same executor:

- `WorkflowPlan` / `WorkflowBinding` / `WorkflowPlanNode` — the Round-1/Round-2
  wire models; `TwoRoundValue` — the `$slot`/`$bind`/`{{label}}` value algebra.
- `WorkflowTwoRoundCompiler` — pure validate / auto-bind / resolve-binding /
  lower-to-`WorkflowSpec` logic (no LLM).
- `ContextHarvesting` — the deterministic local context-harvest protocol;
  `ContextPacket` / `HarvestedCandidate` — its output.
- `WorkflowTwoRoundSchema` / `WorkflowTwoRoundPrompt` — schema assets and the
  versioned planner/binder instructions.
- `WorkflowPlanCache` — caches the Round-1 plan so a repeated intent skips the
  planner call.

The runtime driver that issues the two LLM calls is `WorkflowTwoRoundRunner`
(in AIKit's `AIKitRuntime`).

The current developer guidance and reproduction recipe live in AIKit
[`AGENTS.md`](https://github.com/PangJiaxin0326/AIKit/blob/main/AGENTS.md). This
README only inventories AIToolKit APIs so the recommendations stay in one place.
The legacy workflow guide files in this package are forwarding pages to that
source of truth.
