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
