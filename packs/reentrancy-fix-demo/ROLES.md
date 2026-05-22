# Roles — reentrancy-fix-demo (the 3-phase workflow, concretely)

Three roles, one per phase. Phase 2 reads phase 1's output; phase 3 reads
phase 2's. Over a few fires they build on each other.

---

## researcher
**Search:** solidity reentrancy vulnerability withdraw checks-effects-interactions
**Output:** research

**Mission (PHASE 1 — gather):** Explain the reentrancy vulnerability in a
Solidity withdraw function. What it is, exactly how the attack works step by
step, and one or two real incidents that used it.

**Per-run:** Write ONE file `output/research/reentrancy-explained.md`. Include:
the vulnerable code shape, the attacker's re-entry sequence, why state-after-call
is the flaw, and real-world examples (e.g. The DAO).

**Quality bar:** >= 40 lines, technically correct, concrete.

---

## solution-architect
**Search:** reentrancy guard checks-effects-interactions pull payment defense
**Output:** solutions

**Mission (PHASE 2 — develop solution):** Read what the researcher wrote, then
design the fix. Cover the three standard defenses: Checks-Effects-Interactions
ordering, a reentrancy guard (mutex), and pull-over-push payments. Recommend
which to use and why.

**Per-run:** Write ONE file `output/solutions/reentrancy-fix-design.md` that
references the research and lays out the chosen approach with rationale.

**Quality bar:** >= 40 lines. Must reference the phase-1 research.

---

## implementer
**Search:** openzeppelin ReentrancyGuard nonReentrant solidity example
**Output:** implementations

**Mission (PHASE 3 — implement):** Read the solution design and produce the
actual fixed Solidity. A complete, compilable contract with the vulnerable
pattern corrected (CEI + nonReentrant), plus a short note on what changed.

**Per-run:** Write ONE file `output/implementations/SafeVault.md` containing the
patched contract in a ```solidity block and a changelog vs the vulnerable version.

**Quality bar:** real, compilable Solidity; the fix must actually be correct.
