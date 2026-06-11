# Migration Guide: Unified `WorkflowTool` & Registry-Free Tools

This release makes two breaking changes:

1. **The one-shot workflow and the two-round workflow collapse into one
   official tool: `WorkflowTool`.** The synthetic `workflow_run` descriptor,
   `WorkflowSchema`, and `WorkflowPromptBuilder` are gone.
2. **`ToolRegistry` is removed.** Tools travel the official FoundationModels
   way — as `[any Tool]` handed to a `LanguageModelSession` (or to a
   `WorkflowTool`). The framework itself notifies the model which tools are
   available; on OS 27 a `LanguageModelSession.DynamicProfile` can additionally
   make tool availability conditional per request.

## Removed API → replacement

| Removed | Replacement |
| --- | --- |
| `ToolRegistry` (actor), `.shared`, `register`, `manifest(for:)`, `call(name:jsonArguments:)` | Pass `[any Tool]` to `LanguageModelSession(tools:)` / `WorkflowTool(tools:)`. For direct name-based dispatch use `WorkflowExecutor(tools:)`; for a single call use `WorkflowExecutor.callTool(_:with:)`. |
| `ToolCall` | Not needed: the session loop parses calls. For non-Apple providers, parse to `GeneratedContent` and call `WorkflowTool.call(arguments:)` directly (its `Arguments` *is* `GeneratedContent`). |
| `WorkflowExecutor.init(registry:)` | `WorkflowExecutor.init(tools: [any Tool])` |
| `WorkflowSchema.descriptor(availableTools:)`, `specSchema`, `minimalSpecSchema` | `WorkflowTool.parameters` (built automatically from the leaf tools) |
| `WorkflowPromptBuilder.planningInstruction`, `workedExample` | `WorkflowTool.instructions()` (contract + manifest + the load-bearing worked example) |
| `Tool.descriptor` (constrained to `Generable` args/output) | `Tool.descriptor` now works for **every** official tool; also `ToolDescriptor(tool:)` |

Unchanged and still public: `WorkflowSpec` / `WorkflowValidator` /
`WorkflowExecutor` (the IR and engine), every `WorkflowTwoRound*` type (wire
models, compiler, schemas, prompts, plan cache) for hosts that keep an
isolated runner, and `ViewTool` / `ViewToolRegistry` (view tools cannot be
official tools — their output is a SwiftUI view, not prompt-representable —
so their registry remains).

## Registering and exposing tools

Before:

```swift
let registry = ToolRegistry.shared
await registry.register(FindContactTool())
await registry.register(SendMessageTool())
let manifest = await registry.manifest(for: ["find_contact", "send_message"])
// build prompt from manifest, parse provider tool calls, dispatch by name…
```

After — the tools go where FoundationModels expects them:

```swift
let session = LanguageModelSession(
    tools: [FindContactTool(), SendMessageTool()],
    instructions: "…"
)
```

Per-view subsetting (the old `manifest(for:)`) becomes either a different
`tools:` array per session or, on OS 27, a `DynamicProfile` whose builder
includes tools conditionally.

## One-shot workflows

Before: synthesize a `workflow_run` descriptor, inject
`WorkflowPromptBuilder.planningInstruction`, parse the spec with
`WorkflowSpec.decodeToolCallArguments`, validate, then execute against the
registry.

After — one tool does all of it:

```swift
let workflow = WorkflowTool(
    tools: [FindContactTool(), SendMessageTool()],
    onResult: { result in
        // Full WorkflowResult (node outputs + trace) for host observability;
        // the model only sees the final value.
    }
)
let session = LanguageModelSession(tools: [workflow]) {
    Instructions(workflow.instructions())
}
let response = try await session.respond(to: "Tell Bob the meeting moved to 3pm")
```

`workflow.instructions()` matters: the schema fixes *structure* but the worked
example supplies *semantics*. Include it in the session instructions.

For non-Apple providers, export `workflow.descriptor` (name, description,
`parameters`) to your wire format; when the provider returns a call, hand the
parsed JSON straight to `try await workflow.call(arguments: content)` and
return the output.

## Two-round workflows

`WorkflowTool` absorbs the protocol; the binding round rides the ordinary
session tool loop instead of a bespoke runner:

```swift
let workflow = WorkflowTool(
    tools: [FindContactTool(), SendMessageTool(), ShareDocumentTool()],
    harvester: AppContextHarvester(),       // your ContextHarvesting impl
    sources: ["current_contact", "foreground_document"]
)
```

- A **self-contained** plan executes immediately (the old one-shot path).
- A plan with slots whose harvest is **deterministic** (single candidate, or a
  unique current/foreground one) auto-binds and executes — still one call; the
  model never learns binding happened.
- An **ambiguous** harvest returns `status: "needs_binding"` with candidate
  ids/labels and a `plan_id`; the model calls the same tool again with
  `{"$bind":"<candidate_id>"}` markers. Candidate **values** never enter the
  output — binding is by id, labels only.
- A missing required slot returns `needs_clarification` so the model can ask
  the user.

Recoverable model mistakes come back as structured outputs the model can fix
in the loop rather than thrown errors. The full status vocabulary:
`completed`, `needs_binding`, `needs_clarification`, `cannot_plan`,
`invalid_plan`, `invalid_binding`, `stale_binding`, `failed`.

### When to use the isolated built-in pair instead

The collapsed tool trades away two properties of the split design. Use AIKit's
built-in tool pair (`WorkflowPlanTool` → `WorkflowExecuteTool`, which drive
`WorkflowTwoRoundCompiler` host-side) if you need:

- **Strict round isolation** — with `WorkflowTool`, candidate *labels* enter
  the shared session transcript (values still never do). The built-in pair
  keeps the planner blind to context and the binder in a separate request with
  tailored instructions.
- **A host interception point between rounds** — between `plan(intent:)` and
  `execute(plan:)` the host can show a native candidate picker, and
  `WorkflowPlanTool` consults `WorkflowPlanCache` to skip the planner call
  entirely. `WorkflowTool` cannot pause the session loop, and it does not
  consult the plan cache (the plan arrives as already-spent model output).

Nothing in the two-round layer was removed; both paths share the same
compiler, validator, and executor.

## Behavior notes

- `WorkflowTool` excludes a nested `WorkflowTool` from its own tool enum;
  workflows do not nest.
- Node tools need outputs that convert to `GeneratedContent` (any `Generable`
  output, including standard types). A prompt-only output is rejected at
  dispatch because it cannot be `$ref`-wired into a DAG.
- Strict argument decoding is preserved: a node input that does not match the
  tool's `Arguments` fails at dispatch, before the tool runs.
- Pending bindings are bounded (oldest evicted beyond 4) and keyed by
  `plan_id`; a bind with no pending plan returns `stale_binding` and the model
  is told to re-emit the plan.
