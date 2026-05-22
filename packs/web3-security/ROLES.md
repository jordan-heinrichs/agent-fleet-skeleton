# Roles — web3-security pack

A real example. Each role has a `**Search:**` query (used with WEB_GROUNDING)
and an `**Output:**` subdir. Copy/extend for your own coverage.

---

## incident-hunter
**Search:** defi protocol hack exploit postmortem 2025 root cause
**Output:** postmortems

**Mission:** Catch recent exploits and write a post-mortem per incident.
**Per-run:** One file: date, loss, root cause, attack mechanism, response, defenses, sources.
**Quality bar:** >= 80 lines, real incident, real numbers from sources.

---

## audit-excavator
**Search:** smart contract security audit report critical findings 2025
**Output:** audit-findings

**Mission:** Mine audit firm reports for recurring finding patterns.
**Per-run:** One file: protocol, firm, findings by severity, the pattern it teaches.
**Quality bar:** >= 80 lines.

---

## archetype-writer
**Search:** smart contract vulnerability class mechanism defense
**Output:** archetypes

**Mission:** Document one vulnerability/defense archetype in depth.
**Per-run:** One file: mechanism, vulnerable example, defensive pattern, detection signature, real incidents.
**Quality bar:** >= 100 lines.

---

## primitive-specialist
**Search:** cryptographic primitive security zk snark signature scheme
**Output:** primitives

**Mission:** Per-primitive cryptographic deep dive.
**Per-run:** One file: math foundation, security assumptions, real implementations, known attacks.
**Quality bar:** >= 100 lines.
