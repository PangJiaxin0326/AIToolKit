# Workflow Guidance Moved

The current workflow and two-round-trip guidance lives in AIKit
[`AGENTS.md`](https://github.com/PangJiaxin0326/AIKit/blob/main/AGENTS.md).
In the standard sibling checkout, the same file is available at
`../AIKit/AGENTS.md`.

This file intentionally no longer carries paradigm rules, measured results,
schema recommendations, model-tier advice, or prompt recipes. Keeping those
details in one place prevents the legacy AIToolKit guidance from drifting away
from the validated AIKit runner configuration.

AIToolKit remains the implementation package for the prompt/schema/value algebra
used by that recipe:

- `Sources/AIToolKit/WorkflowTwoRoundPrompt.swift`
- `Sources/AIToolKit/WorkflowTwoRoundSchema.swift`
- `Sources/AIToolKit/WorkflowTwoRound.swift`
- `Sources/AIToolKit/WorkflowTwoRoundCompiler.swift`
