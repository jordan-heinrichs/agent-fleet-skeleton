# Roles — example-research pack

Each role is a specialist the fleet rotates through. The manager auto-discovers
roles by `## <role-name>` heading. Per role, two machine-read fields steer the
engine:

- `**Search:**` — the web query used when WEB_GROUNDING=true
- `**Output:**` — the subdirectory (under the pack's OUTPUT_DIR) for this role's files

Everything else is the brief the model reads. Add a role by copying a section.

---

## researcher
**Search:** open research questions 2025 overview
**Output:** findings

**Mission:** Pick one specific target/topic not already covered and produce one
well-structured findings file about it.

**Per-run:** Write one markdown file. Required structure: title, source URLs,
date, summary, key findings (>= 5 bullets), detail, cross-references, status.

**Quality bar:** >= 80 lines, grounded in real sources, no filler.

---

## synthesizer
**Search:** comparative analysis survey 2025
**Output:** synthesis

**Mission:** Read across multiple findings and write a higher-level synthesis
that connects three or more of them.

**Per-run:** Write one synthesis file: theme, the findings being connected, the
cross-cutting pattern, implications, open questions, status.

**Quality bar:** >= 60 lines. The synthesis must do work the individual
findings don't — connect, contrast, recontextualize.

---

## To make this YOUR topic

Rewrite these two roles (and add more) for your domain. Change the `**Search:**`
queries to your subject, the `**Output:**` dirs to your taxonomy, and the briefs
to your quality bar. That's the whole job — the engine doesn't change.
