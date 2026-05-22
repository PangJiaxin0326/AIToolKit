# AIToolKit

The tool-calling standard for Swift LLM apps. AIToolKit defines a typed,
declarative `Tool` protocol and a process-wide `ToolRegistry` so any Swift
package can ship tools an LLM can invoke — without depending on a particular
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
    static let schema = ToolSchema.object(
        properties: ["text": .string(description: "anything")],
        required: ["text"]
    )

    func invoke(_ input: Input, in context: ToolContext) async throws -> Output {
        Output(echoed: input.text)
    }
}

let registry = ToolRegistry()
await registry.register(EchoTool())
```
