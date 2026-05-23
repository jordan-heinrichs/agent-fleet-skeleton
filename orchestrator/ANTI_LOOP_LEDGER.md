# ANTI-LOOP LEDGER

**Purpose:** Append-only list of every file the fleet has produced, tagged
with worker role + fire ID. Workers MUST grep this before researching to
avoid duplicate work.

**Format:** `- <path/to/file> ← <role> (fire #N)`

The manager rotates roles based on counts here too. Roles with the fewest
ledger entries get picked first, which biases the fleet toward
underrepresented work without anyone having to think about it.

---

## How to use this file

Workers do two things:

1. Before picking a target, grep the ledger. If the target slug already
   appears, abort and pick another.
2. After writing a file, append one line.

The manager does one thing: count `← <role>` occurrences per role to drive
the rotation picker.

---

## Append fleet entries below this line

<!-- New entries go here, newest at top. Format:
- path/to/file.md ← role-name (fire #N)
-->
- ./packs/example-research/output/findings/long-context-llms-scaling-challenges-2025.md ← researcher (fire #2)
- ./packs/example-research/output/findings/long-context-llms-scaling-challenges-2025.md ← synthesizer (fire #2)
- ./packs/example-research/output/synthesis/llm-benchmark-reliability-measurement-gap-2025.md ← synthesizer (fire #2)
- ./packs/example-research/output/findings/llm-hallucination-mitigation-strategies-2025.md ← researcher (fire #3)
- ./packs/example-research/output/findings/llm-hallucination-mitigation-strategies-2025.md ← synthesizer (fire #3)
- ./packs/example-research/output/synthesis/long-context-reasoning-measurement-gap-2025.md ← synthesizer (fire #3)
- ./packs/example-research/output/findings/training-data-quality-synthetic-data-contamination-2025.md ← researcher (fire #4)
- ./packs/example-research/output/findings/training-data-quality-synthetic-data-contamination-2025.md ← synthesizer (fire #4)
- ./packs/example-research/output/synthesis/prompt-engineering-in-context-learning-capability-scaling-2025.md ← synthesizer (fire #4)
- ./packs/example-research/output/findings/agent-architectures-tool-use-llms-2025.md ← researcher (fire #5)
- ./packs/example-research/output/findings/agent-architectures-tool-use-llms-2025.md ← synthesizer (fire #5)
- ./packs/example-research/output/synthesis/mechanistic-interpretability-modular-circuits-safety-alignment-2025.md ← synthesizer (fire #5)
- ./packs/example-research/output/findings/llm-parameter-efficiency-quantization-lora-2025.md ← researcher (fire #6)
- ./packs/example-research/output/findings/llm-parameter-efficiency-quantization-lora-2025.md ← synthesizer (fire #6)
- ./packs/example-research/output/synthesis/retrieval-augmented-generation-architecture-grounding-agentic-systems-2025.md ← synthesizer (fire #6)
- ./packs/example-research/output/findings/test-time-compute-scaling-inference-reasoning-2025.md ← researcher (fire #7)
- ./packs/example-research/output/synthesis/instruction-tuning-efficiency-quality-tradeoff-2025.md ← researcher (fire #7)
- ./packs/example-research/output/findings/test-time-compute-scaling-inference-reasoning-2025.md ← synthesizer (fire #7)
- ./packs/example-research/output/synthesis/instruction-tuning-efficiency-quality-tradeoff-2025.md ← synthesizer (fire #7)
