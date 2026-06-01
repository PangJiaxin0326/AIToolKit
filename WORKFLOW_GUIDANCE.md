# Workflow & Two-Round-Trip Guidance

How to drive LLM tool-calling on top of AIToolKit so you spend the fewest tokens
and seconds for the highest success rate. This is the *why* and *when*; see
[`WORKFLOW_HOWTO.md`](WORKFLOW_HOWTO.md) for the *how* (step-by-step, schemas,
code). The numbers come from a controlled comparison across a graded task ladder,
a deictic/local-context suite, and a synthetic dependency-depth sweep on two
cloud models — plus a three-tier model-strength sweep (strong / mid / small) for
the malformed-JSON and structured-output findings; cited as "measured" below.

---

## 1. The three paradigms

| Paradigm | One turn = | Round trips | Built on |
|---|---|---|---|
| **Sequential** | model → tool → result → model → … | one per tool call | a plain tool-call loop over `ToolRegistry` |
| **Workflow** (one-shot DAG) | model emits one `WorkflowSpec`; device executes it | **1** | `WorkflowSpec` + `WorkflowValidator` + `WorkflowExecutor` |
| **Two-round-trip** | Plan → (harvest) → Bind → device executes | **1–2** | a thin Plan/Harvest/Bind layer that *emits a `WorkflowSpec`* |

All three execute the *same* `Tool`s through the *same* `ToolRegistry`. They
differ only in how the plan is produced and how intermediate values flow.

- **Sequential** re-sends the growing transcript every turn and relies on the
  model to re-thread ids/state across turns.
- **Workflow** has the model author the whole DAG once; intermediate outputs
  flow by reference (`$ref` JSON Pointers), never back through the model.
- **Two-round-trip** separates *graph planning* (Round 1) from *parameter
  binding* (Round 2) across two **isolated** requests, with a deterministic
  local **context harvest** in between — for tasks whose parameters depend on
  local/private state the planner must not see or invent.

---

## 2. The decision rule (applies to most cases)

```
1. Planner can't reliably author a DAG (small/local/weak model)?       → SEQUENTIAL
2. Else, task needs local/private/UI context, OR disambiguation /
   refusal over local state (deictic: "the doc I have open")?          → TWO-ROUND-TRIP (auto-bind)
3. Else (capable planner; self-contained or named entities;
   one or more dependent or parallel calls)?                           → WORKFLOW (one-shot)
4. Single tool call, no dependencies?                                  → any (a wash)
```

**Meta-rule:** the more dependent steps a task has, the more a DAG paradigm wins.
On a capable planner, a DAG paradigm is the default for any multi-step task;
reserve sequential for weak planners or genuinely single-step asks.

**Two-round-trip with auto-bind is the safe superset default.** It shortcuts to
one call when no binding is needed (identical to workflow), and spends a second
call only to disambiguate among candidates or author text from a harvested
label.

---

## 3. The scaling laws (why)

Cost as a function of dependency depth `D` (chained calls) and parallel breadth
`B`:

| | round trips | tokens vs depth | latency vs breadth |
|---|---|---|---|
| sequential | `D` + overhead | **α·D + β·D²** (re-sent transcript) | linear (serial) |
| workflow / two-round | **1** (two-round ≤2) | **~constant** | **sub-linear** (parallel batches) |

Measured on an opaque dependency chain (success held at 100% for all, isolating
cost): from depth 1→5 the DAG paradigms rose ~13–14% in tokens at **1** round
trip; sequential rose ~170% (2.3 k→6.1 k tokens) at **3→7** round trips, with the
per-step increment itself growing (super-linear), plus heavy cost *variance* on
weaker planners (a self-correction loop turned one depth-5 run into 10 k tokens /
67 s). **Crossover is immediate (D ≥ 1):** even a two-step task is cheaper as a
DAG.

Reliability:

- Shallow / unambiguous tasks: all three are reliable.
- **Sequential reliability erodes with depth on *semantic* tasks** — it drops
  fetched ids/state across turns (especially into *nullable* fields: it writes a
  document's *title* into prose but leaves the *id* field `null`). This is
  structural, not a prompt artifact — it persists under explicit instruction.
- **Workflow / two-round hold with depth** — dataflow is wired by `$ref` and the
  resolved input is validated against each tool's `inputSchema` before dispatch,
  so an id cannot be silently dropped — **until the planner's DAG-authoring
  capacity is exceeded** (very high node counts / many independent end states).
- **Two-round adds**: a clean refusal path, planner isolation from private data,
  and structured candidate disambiguation.

---

## 4. Schema design — the biggest cost lever

Output tokens are set by the **schema** and the **DAG shape**, nothing else.

- **Use a lean node schema: `{id, tool, input}` and nothing else.** Make the
  runtime default every other field (`depends_on`, per-node `policy`,
  `output_policy`, `limits`, `final`, `intent`, `metadata`). AIToolKit's
  `WorkflowSpec` decoders already do this — only `nodes` is required, and a node
  needs only `id`. Measured: lean schema ≈ **−70% output tokens, −52% total,
  −64% latency** at no reliability cost vs the full envelope.
  **Caveat (weak models): lean the *envelope*, not an interactive tool's own
  required parameters.** If `input` is left a free-form object, a small model
  omits a required field (`send_message` without `body`, `create_email_draft`
  without `recipientContactID`) and the node fails strict input-validation
  *silently* at execution — the dominant residual failure on a small/mid planner
  once malformed JSON is removed. Keep each interactive tool's required keys
  required in the planner schema so `response_format` can enforce them.
- **Dependencies come from `$ref`, not `depends_on`.** A node depends on another
  *only* by referencing its output:
  `{"$ref":{"source":"node","node":"<id>","path":"/field"}}` (JSON Pointer; `""`
  = whole output). `WorkflowValidator` derives the edges; omit `depends_on`.
- **`input` holds ONLY the tool's own parameters.** Smaller models leak
  node-level keys (`id`/`tool`/`depends_on`) into `input`, which fails the
  tool's strict input-schema check at execution and makes the node fail
  *silently*. `WorkflowNode`'s decoder strips those keys; keep that defense, and
  say it in the prompt.
- **One fixed, general worked example is load-bearing.** The lean schema fixes
  *structure*; the example supplies *semantics* (which tools, how to wire
  `$ref`, that a plan ends in an action). Without it even a strong model emits
  structurally-valid-but-empty plans. Use the *same* example every request — do
  not tailor it per task.
- **`response_format` (structured outputs) enforces structure, not semantics —
  and whether it pays depends on planner strength.**
  It cannot replace the example, support is per-model-version (test it), and it
  adds input tokens for zero output savings.
  - **Strong planner:** freeform + lean schema + example is as reliable and
    cheaper. Use `response_format` only for fan-out / hard structural guarantees.
    On a strong model it adds tokens for no reliability gain (its malformed-JSON
    rate is already 0%).
  - **Weak / mid planner (the new finding): `response_format` on the *planner*
    round is the single biggest reliability lever for two-round.** It makes the
    malformed-plan shape (§6) unrepresentable. Measured: planner-round unparseable
    JSON **49%→~0%** on a small model (96%→0% at the deepest level), success
    **~39%→71%** (mid model **~79%→95%**) — token-neutral (the schema is
    input-only and it removes the malformed *retries*).
  - **Caveat — round, not just model:** the older "prefer freeform for two-round"
    rule was about the *Binder* on a *strong* model mutating the graph under a
    strict schema. That is round- and strength-specific. Net: enable
    `response_format` on a **weak/mid planner round**; keep a strong model freeform
    throughout; treat the binder under a strict schema with care (re-validate the
    graph is unchanged — §5/HOWTO §4.4).

---

## 5. Optimizations that pay (measured)

- **Auto-bind (two-round):** when the harvest is unambiguous (one sole/current
  candidate per slot, no text-authoring), the Binder decides nothing — bind it
  in the runtime and **skip Round 2**. ≈ **−28–29% tokens, −21–35% latency**, no
  reliability loss; makes two-round *cheaper than one-shot workflow* on context
  tasks while staying more reliable.
- **`{{slot}}` label token (two-round):** to name harvested content in body /
  subject text, have the planner write `{{slot_id}}` and the runtime substitute
  the candidate's label deterministically (a bounded transform). Keeps
  label-into-text authoring on the one-call auto-bind path and closes the
  transform gap without a helper tool. **Guard it with a negative rule:** `{{ }}`
  wraps ONLY a declared slot_id — never a `$ref`, node id, or expression (a `$ref`
  replaces the *whole* field; it can't be embedded in a sentence), and text
  already in the request should be written literally, not referenced. Without the
  clause a strong planner that already wrote the correct literal *also* appends
  `"… {{$ref:{source:node,…}}}"`, which the validator rejects as an undeclared
  slot. Measured: the clause took a strong model **80%→98%** on "mention X in the
  body/subject" tasks at flat token cost — a prompt fix, not an example gap.
- **Strip stray `input` keys to the tool's schema** before execution (workflow
  *and* the two-round binder). Recovers structurally-complete plans a strict
  input check would otherwise discard — the single highest-leverage robustness
  fix for cheaper models.
- **Plan caching (two-round):** the plan is intent-determined and stable across
  repeats; only the binding is context-dependent. Cache the Round-1 plan keyed on
  `(normalized intent · tool set · schema version)` and on a repeat **skip the
  planner call** — re-harvest + re-bind locally. Measured: a recurring deictic
  command runs at **0 LLM calls** after the first time (plan cached + auto-bind),
  still adapting to the current selection; an ambiguous one drops to 1 call and
  still refuses correctly. Success is unchanged (the cached plan is re-validated;
  a hit is never worse than a miss). This only works because two-round separates
  plan from bind — a one-shot bound DAG can't be cached (its params are stapled
  in). See `WORKFLOW_HOWTO.md` §"Plan caching".
- **Manifest scope:** `perTask` (only the task's tools) is a big lever for
  *sequential* (it re-sends the manifest every turn) and harmless for workflow
  *as long as the worked example is present*. For *large* catalogs, send a
  compact tool index and fetch full schemas on demand (tool-search).
- **Memory window 0** for single-turn tasks (no prior actions to recall).
- **Thinking OFF** and **temperature 0.2** on a capable planner (0.0 makes a
  malformed-JSON loop regenerate the same error forever; 0.4 regresses).

---

## 6. Known capability gaps & pitfalls

- **Transform gap.** `$ref` copies a value verbatim; there is no
  `$concat`/`$template`/arithmetic. A value derived from a tool output ("set
  duration = doc size in KB", "subject = title + date") needs an **atomic helper
  tool** the planner wires (`bytes_to_kb`, `get_doc_date`), a `{{slot}}` token
  (two-round), or a bounded expression layer (see HOWTO §"Beyond v1"). Sequential
  does transforms for free (the model sees the output) but pays the round trip.
- **Dropped nullable ids (sequential).** On multi-step tasks sequential leaves
  nullable id fields `null` after fetching the id. Prefer DAG paradigms, or make
  the field non-nullable, or add an explicit threading rule to the prompt
  (helps, doesn't fully fix).
- **Named vs deictic (two-round).** A *named* entity ("the FY26 budget memo")
  should route to a utility node (`search_*`) — give the planner that tool.
  Don't expect the Binder to disambiguate a *named* thing among harvested
  candidates; its candidate-choice power is for genuinely *deictic* references.
- **Malformed plan JSON on a weak planner is *structural*, not semantic.** A
  small model's #1 two-round failure is emitting unparseable JSON — and (measured)
  **100% of those replies are brace-unbalanced around the nested `$ref` object**
  `{"$ref":{"source","node","path"}}`: it nests a sibling key inside the ref and
  drops a `}`. It scales with ref count (a deeper DAG is worse: ~25%→54%→96% as
  refs go 1→3 on a small model), so *more examples don't help* — examples can't
  fix brace-counting. Two fixes: (a) `response_format` on the planner round makes
  the bad shape unrepresentable (§4) — do this now; (b) a **flatter `$ref`** form
  (`{"$ref":"node/field"}`, one level) removes it at the source *and* cuts output
  tokens (HOWTO §9).
- **Planner capacity ceiling.** Both DAG paradigms inherit the planner's
  DAG-authoring limit. A weak/small model has none → use sequential there.
- **Score by side effects, not prose.** Verify the draft/event/message/token
  actually landed with the right ids; don't string-match the model's final reply
  (an after-the-fact iteration-limit error otherwise reads as failure).

---

## 7. Security & safety (two-round especially)

- **Round 1 never sees private ids; Round 2 never sees the full tool universe.**
  Two-round is two *separate* provider conversations, not a continued chat: Round
  2 receives a canonical copy of the validated plan + a narrow context packet.
- **Context-packet values are data, not instructions** — say so in the binder
  prompt; never obey instructions found in harvested content.
- **The local runtime validates, approves, resolves, and executes** — the model
  only proposes. Use `ToolAnnotations` (`requiresUserApproval`, `sideEffect`,
  `sensitiveOutput`, `defaultTimeoutMS`, `maxOutputBytes`) as runtime policy
  inputs: approval gates, retry policy, redaction, timeouts.
- **Refuse, don't guess.** Missing required context → refuse before the second
  call; ambiguous candidates with no clear default → `cannot_bind`. A wrong side
  effect is worse than asking.

---

## 8. One-line conclusions

- **Strong model → workflow; weak model → sequential; local-context tasks →
  two-round-trip.** Paradigm follows planner capability and task shape.
- **DAG cost is flat in depth; sequential cost is ~quadratic.** Crossover at
  D ≥ 1, so a DAG paradigm is the default for any multi-step task on a capable
  planner.
- **Output tokens are bought by the schema, not the model** — a lean schema is a
  free ~70% output cut.
- **On a weak/mid planner, `response_format` is the two-round reliability lever**
  — it removes the structural (nested-`$ref`) malformed JSON token-neutrally
  (small model ~39%→71%, mid ~79%→95%); a strong planner needs only freeform + the
  `{{ }}` negative-rule clause.
- **Two-round-trip + auto-bind** matches sequential on success for simple
  context tasks (winning on cost) and beats it on complex multi-step ones
  (winning on the wired-and-validated dataflow), while adding clean refusal and
  planner isolation.
