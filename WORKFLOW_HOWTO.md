# How to use Workflow & Two-Round-Trip on AIToolKit

A practical, end-to-end guide. Read [`WORKFLOW_GUIDANCE.md`](WORKFLOW_GUIDANCE.md)
first for *when* to use each paradigm and *why*; this doc is *how*. All snippets
use AIToolKit types only; the LLM transport is yours (anything that returns text
or a tool call).

Contents: §1 the node value algebra · §2 one-shot workflow · §3 authoring tools
well · §4 the two-round-trip layer · §5 auto-bind · §6 `{{slot}}` tokens ·
§7 recipes · §8 plan caching · §9 beyond v1.

---

## 1. The node value algebra

Every node `input` value is one of:

| Form | Meaning | Stage |
|---|---|---|
| a bare JSON value | literal | any |
| `{"$literal": <value>}` | explicit literal (use when the value itself looks like a ref) | any |
| `{"$ref":{"source":"node","node":"<id>","path":"/p"}}` | another node's output (JSON Pointer; `""`/`"/"` = whole output) | any |
| `{"$ref":{"source":"context","path":"/p"}}` | a value from the execution context object | any |
| `{"$slot":"<slot_id>"}` | Round-1 placeholder for local context (two-round) | plan only |
| `{"$bind":"<candidate_id>"}` | Round-2 chosen candidate (two-round) | binding only |
| `"… {{slot_id}} …"` | substitute a harvested label into text (two-round) | resolved locally |

`$ref`/`$literal` are resolved by `WorkflowReferenceResolver`; `$slot`/`$bind`/
`{{}}` are a two-round convention your layer resolves into literals/`$ref`s
*before* building the final `WorkflowSpec`, so the validator/executor run
unchanged.

> **Weak-model gotcha:** the 3-level nested `$ref` object is the #1 malformed-JSON
> trigger on a small planner — it mis-balances the braces (nests a sibling key
> inside the ref, drops a `}`). On a weak/mid planner constrain the planner with
> `response_format` (§4.5); a flat one-level `$ref` alias is the deeper fix (§9).

---

## 2. One-shot workflow

### 2.1 The lean `WorkflowSpec` the model should emit

```json
{
  "schema_version": "workflow.v1",
  "nodes": [
    {"id": "find_bob",   "tool": "find_contact", "input": {"query": "Bob Singh"}},
    {"id": "send_hello", "tool": "send_message",
     "input": {"contactID": {"$ref": {"source":"node","node":"find_bob","path":"/contactID"}},
               "body": "Hi Bob…"}}
  ]
}
```

Only `nodes` is required; every other field defaults (`WorkflowSpec.init(from:)`).
A node needs only `id` (and a `tool` to be runnable). Emit source nodes before
consumers; dependencies are derived from `$ref`s — omit `depends_on`.

### 2.2 The pipeline

```swift
import AIToolKit

// 1. Build the manifest for the tools in scope (per-view / per-task subset).
let descriptors = await registry.manifest(for: toolNames)

// 2. Prompt the model. Use the planning instruction + ONE fixed worked example;
//    keep `input` to the tool's own params; reference outputs with $ref.
let instruction = WorkflowPromptBuilder.planningInstruction(
    toolManifest: descriptors, minimal: true   // `minimal` = the lean schema
)
// (Optionally constrain with response_format using
//  WorkflowSchema.minimalSpecSchema(availableTools: descriptors).)

// 3. Parse the model's reply into a WorkflowSpec.
let spec = try WorkflowSpec.decodeToolCallInput(modelToolCallInput)   // or decode JSON content

// 4. Validate locally (graph shape, tool availability, schemas, limits).
let validated = try WorkflowValidator.validate(
    spec, policy: WorkflowValidationPolicy(descriptors: descriptors)
)

// 5. Execute the DAG through the registry (topological batches, parallel where safe).
let executor = WorkflowExecutor(registry: registry)
let result = try await executor.execute(
    validated, context: WorkflowExecutionContext(toolContext: ToolContext(viewID: viewID))
)
// result.finalText / result.nodeOutputs / result.trace
```

`WorkflowValidator` checks: supported `schema_version`, unique/valid node ids,
known+available tools, acyclic graph, dependencies exist and are topological,
`$ref` paths exist in the referenced node's `outputSchema` (when present),
literal inputs validate against `inputSchema`, and size/limit bounds.
`WorkflowExecutor` resolves references, validates each *resolved* input against
the tool `inputSchema`, dispatches via `ToolRegistry`, validates output against
`outputSchema`, applies per-node `policy` (timeout/retry/on_error) and
`output_policy` (store/expose/redact), and runs independent nodes concurrently
up to `limits.max_parallelism`.

### 2.3 Robustness: strip stray keys

Cheaper models leak node-level keys into `input`. `WorkflowNode`'s decoder
already strips `id/kind/tool/depends_on/policy/output_policy` and coerces a
`null` input to `{}`. If you build the spec yourself from a looser shape, prune
each node's `input` to the keys present in the tool's `inputSchema.properties`.

---

## 3. Authoring tools well (tool quality = workflow quality)

- **Descriptions** state what it does, when (not) to use it, side effects, and
  the **stable output fields** downstream nodes can reference.
- **Input schemas**: prefer `ToolSchema.strictObject` (all required fields
  declared, `additionalProperties:false`, enums over free strings, bounded
  arrays, nullable only when truly optional). The stricter the schema, the less
  the planner can get wrong.
- **Output schemas**: provide them for any tool whose output feeds another node
  — without one, the planner can't safely produce `$ref` paths and the validator
  can't check them.
- **`inputExamples`** for nested/format-sensitive inputs.
- **`ToolAnnotations`** are runtime policy, not docs: `isReadOnly`/`isIdempotent`
  (retry), `sideEffect`/`requiresUserApproval` (approval gates),
  `allowedWithoutNetwork` (offline), `defaultTimeoutMS`, `maxOutputBytes`,
  `sensitiveOutput` (redaction / don't re-send to an LLM), `resultSummaryHint`.
  Be conservative — if unsure, mark risk higher.
- **Keep outputs metadata-only** (ids, titles, summaries) — never bulk bodies.
  In workflow this is structural (refs carry shape, not bytes); in sequential
  it's discipline (fat outputs compound every turn).

---

## 4. The two-round-trip layer

This ships as real types: AIToolKit has the pure pieces (`WorkflowPlan`,
`WorkflowBinding`, `TwoRoundValue`, `WorkflowTwoRoundCompiler`,
`ContextHarvesting`/`ContextPacket`, `WorkflowTwoRoundSchema`/`Prompt`,
`WorkflowPlanCache`); AIKit's `AIKitRuntime` has the driver
`WorkflowTwoRoundRunner` that issues the two LLM calls. To use it, conform a
`ContextHarvesting` to your local state and run:

```swift
let runner = WorkflowTwoRoundRunner(
    llm: client, tools: registry,
    harvester: MyHarvester(),                       // reads your local selection
    plannerToolNames: toolNames.subtracting(["get_active_context"]),
    options: .init(model: model, sources: ["current_contact", "foreground_document"],
                   autoBind: true),                 // freeform; auto-bind on
    planCache: WorkflowPlanCache())                 // optional (§8)
switch await runner.run(intent: userText).outcome {
case .executed(let result): …                        // ran the bound DAG
case .refused(let why):     …                        // cannot_plan / cannot_bind / missing
case .failed(let why):      …                        // malformed / validation / exec error
}
```

The compiler **emits a `WorkflowSpec`** for the final execute step, so everything
in §2 is reused. The rest of this section explains what each stage does.

### 4.1 Lifecycle

```
intent + tool descriptors
   │  Round 1 (Planner, isolated request)
   ▼  → abstract plan: lean nodes + declared context_slots + outcome
local validation (tool names, acyclic, every $slot declared, no invented ids)
   ├─ outcome == self_contained  → build spec, execute (ONE call)            [shortcut]
   ├─ required slot missing       → refuse (no second call)
   └─ else: deterministic harvest (NO LLM) → context packet (candidates)
            ├─ unambiguous + auto-bind on → bind locally, execute (ONE call) [§5]
            └─ Round 2 (Binder, fresh request) → full bound nodes
                 → validate (graph unchanged, $slot→$bind of the right slot)
                 → resolve $bind/{{}} into literals → build spec → execute
```

The two calls are **separate provider conversations** (fresh requests), never a
continued chat. Round 1 sees the tool universe but not the private ids; Round 2
sees only the selected tools + the harvested packet.

### 4.2 Round-1 Planner output (lean)

```json
{
  "outcome": "requires_binding",
  "intent_summary": "Message the foreground contact about the open doc.",
  "nodes": [
    {"id": "send", "tool": "send_message",
     "input": {"contactID": {"$slot": "current_contact"},
               "body": "Reminder about {{foreground_document}}."}}
  ],
  "context_slots": [
    {"slot_id": "current_contact",    "source": "current_contact",    "reason": "…", "required": true},
    {"slot_id": "foreground_document","source": "foreground_document","reason": "…", "required": true}
  ]
}
```

`outcome` ∈ `self_contained | requires_binding | cannot_plan`. Derive the
*effective* outcome from structure (any `$slot`/declared slot ⇒ requires
binding), not just the label.

### 4.3 Harvest (deterministic, local, no LLM)

For each declared slot, read the trusted local source (current selection,
foreground doc, defaults), rank the foreground/current candidate first, cap the
count, and produce candidates `{candidate_id, label, value, isCurrent}`. **Report
missing — never fabricate.** A required-and-missing slot → refuse before the
second call.

### 4.4 Round-2 Binder output (Schema A: full bound DAG)

The Binder receives the validated nodes + selected descriptors + the packet, and
returns the **same** nodes with each `{"$slot"}` replaced by
`{"$bind":"<candidate_id>"}` (choosing among candidates). Validate: node count /
ids / tools / order unchanged; no leftover `$slot`; every `$bind` references a
candidate **of that slot**. Then resolve `$bind` → the candidate's literal id
(and `{{slot}}` → its label), and build the `WorkflowSpec`.

Binder returns `cannot_bind` (with `missing_slots`) when a required slot is
missing or several candidates are plausible with no clear default. Treat a clean
refusal as **success** for "should-not-act" situations.

### 4.5 Robustness (same levers as workflow)

- One bounded **retry** on a transient (network error or no-JSON response): each
  round is a stateless request, so re-issuing it once is faithful (not chaining).
  Note the retry *masks* malformed JSON in the success rate but not in cost —
  measure the raw per-call malformed rate, not just terminal failures.
- **On a weak/mid planner, set `useStructuredOutput` for the planner round.** Pass
  `WorkflowTwoRoundSchema.planner(toolNames:sources:)` as the `response_format`;
  the strict schema makes the nested-`$ref` malformed shape (§1) unrepresentable.
  Measured: planner-round unparseable JSON **49%→~0%** on a small model (96%→0% at
  the deepest level), success **~39%→71%** (mid ~79%→95%), token-neutral (input
  schema only, and it removes the malformed retries). A strong planner doesn't
  need it (already 0% malformed). Keep each interactive tool's required keys
  **required** in that schema (§2.3) so missing-`body`/`contactID` can't slip
  through.
- **Prune stray `input` keys** to the tool schema before execution (the binder
  leaks keys too).

---

## 5. Auto-bind — skip Round 2 when there's no decision

Before calling the Binder, check whether binding is deterministic: every
*referenced* slot (via `{"$slot"}` **or** a `{{slot_id}}` token) resolves to a
single candidate — the sole one, or the unique `isCurrent` one — and no declared
slot is *unreferenced* (an unreferenced slot signals free-text authoring the
Binder must phrase). If so, substitute the chosen value (`$slot`→id) and label
(`{{slot}}`→title) locally and execute — **one call**. Otherwise fall through to
the Binder. It's provably equivalent (a single candidate is the only thing the
Binder could pick) and cuts ≈28–29% of tokens.

---

## 6. `{{slot}}` label tokens

When body/subject text must *name* harvested content the planner can't see, the
planner writes the placeholder where the name goes
(`"Reminder about {{foreground_document}}"`) and declares the slot; the runtime
substitutes the chosen candidate's label (stripped of any provenance hint) — on
both the auto-bind and binder paths. Bind ids with `$bind`/`$slot`; never paste a
raw id into prose.

**Negative rule (load-bearing on a strong planner).** Tell the planner that
`{{ }}` wraps ONLY a declared slot_id — never a `$ref`, node id, or expression (a
`$ref` replaces the *whole* field; it cannot be embedded in a sentence), and that
text already in the request should be written **literally**, not referenced.
Without it, a capable model writes the correct literal *and then* appends
`"… {{$ref:{source:node,node:find_doc,path:/hits/0/title}}}"` for the exact stored
title, which the validator rejects as an undeclared slot. The exact clause:

> `{{ }}` wraps ONLY a slot_id you declared — never a `$ref`, a node id, or any
> expression. A `$ref` replaces the WHOLE field value; it cannot be embedded in a
> sentence. If the text is already in the user's request (a named document or
> person), just write it literally; do not reference a tool's output inside
> body/subject text.

Measured: `{{$ref}}` misuse 12/20→0/20, success **80%→98%** on "mention X in the
body/subject" tasks, tokens flat. It is a *prompt* fix — adding another example
does **not** stop the misuse (the model is over-generalizing the existing one).

---

## 7. Recommended recipes

```sh
# Capable cloud model, self-contained / named multi-tool tasks — cheapest:
WORKFLOW:    lean schema (id/tool/input only) + one fixed example
             + perTask manifest + mem 0 + thinking off + temperature 0.2
             (response_format optional; add it for fan-out structural guarantees)

# Strong cloud model, deictic / local-context tasks — safe superset default:
TWO-ROUND:   lean planner+binder schemas + two-slot worked example + {{slot}} tokens
             + the "{{ }} wraps only a slot_id; write known text literally" clause (§6)
             + auto-bind ON + freeform + temperature 0.2
             (self-contained asks shortcut to one call automatically)

# Mid / small planner still doing two-round — ADD structured output on the planner:
TWO-ROUND+:  same as above, but response_format = WorkflowTwoRoundSchema.planner(...)
             (useStructuredOutput) — removes the nested-$ref malformed JSON
             (96%→0% at the deepest level on a small model; success ~39%→71%,
             mid ~79%→95%), token-neutral. Keep interactive tools' required keys
             required so the schema enforces them. A strong planner needs neither.
             (But if the model can barely author a DAG at all, prefer SEQUENTIAL.)

# Small / local / weak planner (can't author a DAG):
SEQUENTIAL:  minimal prompt + perTask manifest + mem 0 + temperature 0.2
             + an explicit "thread fetched ids into id fields; do every action;
               refuse rather than guess" rule; keep the id-quoting rule
```

---

## 8. Plan caching — drive recurring intents to zero LLM calls

The plan (which tools, which slots, the DAG) is *intent-determined* and stable
across repeats; only the *binding* depends on the current context. So cache the
Round-1 plan and skip the planner on a repeat — then re-harvest and re-bind
locally so the result still adapts to the current selection.

```swift
let key = PlanCacheKey(intent: normalized(intent),
                       tools: plannerToolNames.sorted(),
                       schema: planSchemaVersion)        // your key type

if let plan = cache[key] {
    // HIT: skip Round 1 entirely. Re-validate (deterministic — the key fixes
    // tools+schema), then harvest → auto-bind/bind → execute, all below.
} else {
    let plan = try await planner.plan(intent, tools: descriptors)   // the only LLM call
    try validatePlan(plan, tools: plannerToolNames)
    cache[key] = plan
}
// … harvest(plan.contextSlots) → autoBind ?? bind(...) → WorkflowExecutor …
```

Measured: a recurring *unambiguous* deictic command (incl. `{{slot}}` authoring)
runs at **0 LLM calls** after the first time; a recurring *ambiguous* one drops to
1 call and **still refuses** (the Binder runs because the harvest is ambiguous —
the cache skips only the planner). Success is unchanged.

Guards: key on `(intent · tools · schema version)` so re-validation on a hit is
deterministic; re-validate anyway and re-plan on any mismatch (never worse than a
miss); harvest/bind always re-run, so the binding is never stale. **Do not** cache
a one-shot bound `WorkflowSpec` — its parameters are stapled in, so replay would
act on a stale id; this technique needs the plan/bind separation two-round
provides.

## 9. Beyond v1 — the bounded-expression workflow

The one remaining structural gap is *value transformation* (concat, arithmetic,
format, map-over-list). v1 answers it with atomic helper tools, `{{slot}}`
tokens, or the Binder. The natural next step is a **small, declarative,
locally-evaluated expression layer** in the node-input algebra — e.g.
`{"$template": "{a} — {b}", "bindings": {…}}`, `{"$map": {"over": <ref>, "as": …,
"node": …}}`, `{"$pick": {"from": <ref>, "where": …}}` — validated and executed
by the runtime, **never** as model-generated code. This keeps multi-step
composition on **one** round trip (closing the transform gap without helper tools
or a second call) while staying safe and inspectable. Keep the set small and
declarative; do not admit arbitrary expressions.

### 9.1 A flatter `$ref` (robustness, not expressiveness)

A second, orthogonal v1.x change targets the weak-model malformed-JSON failure at
its source. The canonical 3-level
`{"$ref":{"source":"node","node":"X","path":"/p"}}` is the dominant malformed-JSON
trigger on a small planner — **100%** of a small model's malformed plans are brace
imbalances around it, and the rate scales with ref count (~25%→54%→96% as refs go
1→3). A **one-level alias** decoded leniently alongside the canonical form —
`{"$ref":"X/p"}` (node output) and `{"$ref":"@/p"}` (context) — would have far
fewer braces to balance, removing the failure for free *and* shaving output
tokens, so even *freeform* stays robust on a small model. Implementation: accept
both shapes in `TwoRoundValue`/`WorkflowNode` decoding (normalize the flat form to
the canonical one), and emit the flat form in the planner prompt + examples.
`response_format` (§4.5) is the ship-now mitigation; the flat `$ref` is the
structural fix that also helps freeform.
