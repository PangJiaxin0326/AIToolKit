# AIToolKit

The tool-calling support package for Swift LLM apps, built directly on
FoundationModels' official `Tool` protocol: tools travel as `[any Tool]`
into a `LanguageModelSession`, and AIToolKit adds a two-tier tool taxonomy
and a staged **select-then-work** workflow profile on top. No third-party
dependencies; Swift 6 strict concurrency, language mode v6.

## What's inside

| Piece | Role |
| --- | --- |
| `Tool` (typealias), `ToolDescriptor`, `ToolError`/`GenericToolError` | The official tool protocol as the base currency, plus provider-facing metadata and retriability-typed errors |
| `AssistiveTool` (+ `TextArgument`/`IntegerArgument`/`EmptyArguments`) | LLM-visible-only *unit requests*: one scalar argument in, one fact string out |
| `FinishingTool` | User-visible finishing actions that register their assistive tools and a `progressText` UI hint |
| `WorkflowProfile`, `WorkflowStage`, `ToolSelection`, `WorkTurnMonitor`, `WorkflowStageComplete` | The select-then-work session paradigm |
| `ViewTool` / `ViewToolRegistry` | View-producing tools the host renders (a SwiftUI view cannot round-trip to the model, so these keep a registry) |
| `GeneratedContent` / `GenerationSchema` helpers | Sugar over the official JSON currency (`.object`, `objectValue`, `allStrings`, `data()`, `jsonString()`, …) |

## The tool split

- **Finishing tools** (`FinishingTool`) are ordinary `@Generable`-argument
  tools — the semantically complete actions a user could tap (send the
  message, create the entry). Each registers the assistive unit requests
  that can resolve its arguments (`registeredAssistiveTools`) and an
  optional `progressText` ("Creating Entry…") for the host's busy UI.
- **Assistive tools** (`AssistiveTool`) take one plain-text string, one
  integer, or nothing, and return one compact fact string. Lookup misses
  return descriptive strings ("no contact matches 'x'"), **never throw**.
  Their austerity is the context-budget lever: a scalar schema costs a few
  tokens where a structured one costs ~100. Filter user-facing surfaces
  with `tool.isAssistive` — assistive tools are never user-visible.

## The select-then-work workflow

One native `LanguageModelSession` over `WorkflowProfile`, two staged calls,
both ended **by host configuration in code** — no model completion signal:

```
step .scope  →  instructions: name the tools, nothing else. The finishing
                catalogue is RENDERED INTO the instructions as text; tool
                calling is DISALLOWED (tool_choice: none) and the reply is
                GUIDED (respond(generating: ToolSelection.self)): a typed
                array of tool names, ~9 output tokens. The model cannot act
                prematurely by configuration.
host validates the selection (validated(against:)), shows the progress
                hint, flips session.properties.workflowStage = .work, sets
                the historyTransform cut index
step .work   →  instructions: the whole job + injected local deictic state.
                tools: the SELECTED finishing tools + their registered
                assistive tools. Ends the moment a fully executed turn
                contains a finishing output (WorkTurnMonitor + a throwing
                onToolOutput hook).
```

The user intent is sent in BOTH calls; the typed selection is the only
thing that crosses the stage boundary, and it crosses host-side. A
cut-index `historyTransform` drops every scope-step entry, so neither call
carries the other's tool set or context.

### Stand up the session (copy this)

```swift
import AIToolKit                       // WorkflowProfile, WorkTurnMonitor
import VolcengineArkFoundationModels   // or any official LanguageModel

let monitor = WorkTurnMonitor(finishingToolNames: finishingNames)
let profile = WorkflowProfile(
    scopeInstructions: { scopeText },           // name the tools, nothing else
    workInstructions: { workText(localState) }, // the whole job + deictic state
    catalogue: finishing,                       // rendered into scope instructions
    workTools: { state.selected() }             // selected + registered assistive
)
.model(model)            // declare .guidedGeneration in its capabilities!
.temperature(0.2)
.historyTransform { entries in
    // The runtime SWAPS the head instructions entry in place on stage flip —
    // ALWAYS keep entry 0, cut 1..<cutIndex.
    entries.enumerated().compactMap { i, e in
        if i == 0, case .instructions = e { return e }
        return i >= state.cutIndex ? e : nil
    }
}
.onToolCall { call in
    if state.stage == .work { monitor.recordCall(call) }
}
.onToolOutput { call, _ in
    // The work step ends HERE, in code: turn fully executed + ≥1 action.
    if state.stage == .work, monitor.recordOutput(call) {
        throw WorkflowStageComplete()
    }
}
.transcriptErrorHandlingPolicy(.preserveTranscript)

let session = LanguageModelSession(profile: profile)
// step 1 — one fast guided round; the TYPED selection is the UI hint
let selection = try await session.respond(
    to: "User request: \(userText)\n\nSelect the task tools this request needs.",
    generating: ToolSelection.self
).content
state.selection = selection.validated(against: finishingNames)
state.cutIndex = session.transcript.count
state.stage = .work
session.properties.workflowStage = .work
// step 2 — host-stopped by WorkTurnMonitor; give it two corrective rounds
_ = try await session.respond(to: "User request: \(userText)\n\nComplete this request now.")
```

### The traps (each one cost a measured battery)

1. **Keep entry 0 in the history transform.** The runtime swaps the head
   instructions entry in place on stage flip; a naive `dropFirst(cut)` cuts
   the new instructions off and the work step runs with no system prompt.
2. **Disallowed tool calling strips tools from the request.** A catalogue
   registered as tools silently vanishes in the scope step — render it into
   the instructions (`WorkflowProfile` does this itself).
3. **Unwrap `LanguageModelSession.ToolCallError`.** Errors thrown inside a
   tool's `call` — and errors thrown from an `onToolCall` hook — reach the
   host wrapped in it; match `underlyingError`. (`onToolOutput` throws
   propagate raw — the host stop relies on this.)
4. **Validate like a real backend.** Small models batch an action with the
   lookup it depends on, binding `{{placeholders}}` or empty strings.
   Finishing tools must reject empty/unknown ids, garbage timestamps, and
   malformed tokens with a thrown error; a corrective respond fixes the run.
5. **Echo lineage in chain-shaped tools.** A tool whose output feeds its
   next call should echo its input (`next token: X (derived from 'Y')`).
6. **No model-side completion signal.** Don't add a `task_complete` tool —
   it reintroduces forgotten-signal rounds, and its call envelope alone
   costs ~10× the guided text selection.

Verified on the OS 27 SDK: **all of a parallel batch's `onToolCall`s fire
before the first tool executes**, so `WorkTurnMonitor` knows the turn's size
before any output lands — a batched sibling action is never cancelled by
the throw, a pure-lookup turn never stops the session, and a refusal ends
on its normal text turn with no special case.

### Prompt rails that are measured to matter

Scope step: "that selection is your ONLY job — reply with ONLY the needed
task tool names"; "if unsure between two tools, include both; lookups and
missing details are handled in the next step."

Work step: "batch ALL independent lookups into ONE turn as parallel tool
calls"; "NEVER call an action tool in the same turn as a lookup it depends
on"; "issue ALL the action calls together in ONE final turn once every id
they need is in hand — the session ends when that turn completes"
(mandatory: it makes the host stop complete-by-construction); always inject
the local-state block with explicit "none selected"/"AMBIGUOUS — do not
guess" lines and the rule that deictic references are already resolved
there (the tools cannot see the user's screen).

### Cost model

Every call is structurally necessary: the scope call (~330 input tokens,
~3 output), one round per dependent hop, the final action turn. Deictic and
refusal tasks = 2 calls; one-lookup actions = 3; a depth-N opaque chain =
N+2. Measured on a 20-task battery (mini-class model): 19/20, step-1 mean
0.66 s at ~9 output tokens, total mean 3.31 s.

## Guardrails

The sibling AIKit package ships an error-driven guardrail engine that rides
the same profile machinery: apply `.guardrails(engine)` (AIKitSafety) to any
profile — including a `WorkflowProfile` chain — and every tool call passes
global policies, with blocks surfacing as the official
`LanguageModelError.guardrailViolation`.
