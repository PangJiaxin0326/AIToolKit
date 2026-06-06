# AIToolKit

The tool-calling standard for Swift LLM apps. AIToolKit defines a typed,
declarative `Tool` protocol and a process-wide `ToolRegistry` so any Swift
package can ship tools an LLM can call — without depending on a particular
runtime or provider.

It has no third-party dependencies, is fully `Sendable`, and builds under
Swift 6 strict concurrency / language mode v6.

## What's inside

- `Tool` — a typed unit of work (`Input`/`Output` are `Codable & Sendable`).
- `ToolContext` — small ambient state handed to a tool at invocation.
- `ToolRegistry` — an actor that registers, subsets, and dispatches tools by name.
- `ToolSchema` / `ToolDescriptor` — JSON Schema builder and the provider-facing
  descriptor sent to the model.
- `JSONValue` — a `Sendable`, `Codable`, numerically-canonical JSON value.
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

struct EchoTool: Tool {
    struct Input: Codable, Sendable { var text: String }
    struct Output: Codable, Sendable { var echoed: String }

    static let name = "echo"
    static let description = "Echoes input back."
    static let inputSchema = ToolSchema.object(
        properties: ["text": .string(description: "anything")],
        required: ["text"]
    )

    func call(_ input: Input, in context: ToolContext) async throws -> Output {
        Output(echoed: input.text)
    }
}

let registry = ToolRegistry()
await registry.register(EchoTool())
```

Tools can also be called directly with `try await tool(input, in: context)`.

## Workflows and two-round-trip APIs

AIToolKit also ships a one-shot **workflow** layer — the model emits one
`WorkflowSpec` (a DAG of tool calls wired by `$ref` JSON Pointers) and the device
validates and executes it locally without re-calling the model:

- `WorkflowSpec` / `WorkflowNode` — the lean IR (`{id, tool, input}` per node;
  every other field defaults).
- `WorkflowValidator` — graph shape, tool availability, schema, and limit checks.
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
