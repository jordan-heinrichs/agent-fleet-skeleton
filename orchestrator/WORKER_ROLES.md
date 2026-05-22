# WORKER ROLES

Each role is a specialist brief that one worker consumes per job. The manager
picks roles from this file by H2 heading (`## <role-name>`). To add a role,
append a new H2 section with the same shape.

The skeleton ships with two example roles. Replace them with your own.

---

## researcher

**Mission:** Read PROJECT_TARGETS.md, pick one target not in the anti-loop
ledger, and produce one well-structured findings file about it.

**Sources:** The web. Use WebSearch and WebFetch as needed.

**Per-run:** Pick ONE target. Write `projects/<project>/findings/<slug>.md`
where `<slug>` is a short kebab-case version of the target name.

**Output structure** (every file must include):

- Source URL and date fetched
- Quality tier (1-5)
- Summary paragraph
- Key findings (at least five bullets)
- Cross-references to at least two existing files in the project
- Status line at the bottom

**Quality bar:** At least 100 lines. No filler. Every section must add signal.

**Anti-loop:** Grep `orchestrator/ANTI_LOOP_LEDGER.md` for the target slug
before writing. If it appears, abort and pick another target.

---

## synthesizer

**Mission:** Read what the researcher role has produced, find patterns across
multiple files, and write higher-level synthesis notes.

**Sources:** The `projects/<project>/findings/` directory.

**Per-run:** Pick a theme that connects three or more existing findings.
Write `projects/<project>/synthesis/<theme-slug>.md`.

**Output structure:**

- Theme name
- Date compiled
- The three or more findings being synthesized (linked)
- Cross-cutting pattern (the actual synthesis)
- Implications
- Open questions
- Status line

**Quality bar:** At least 80 lines. The synthesis must do work the individual
findings don't — connect, contrast, or recontextualize.

**Anti-loop:** If a theme has already been synthesized (check the ledger),
pick a different theme or abort the run.

---

## Adding a new role

Copy the structure above. Required fields:

- `## <role-name>` heading (lowercase, kebab-case, no spaces)
- **Mission** — one paragraph
- **Sources** — where the role pulls from
- **Per-run** — what one job produces
- **Output structure** — required file shape
- **Quality bar** — concrete minimum
- **Anti-loop** — how to avoid duplicate work

The manager auto-discovers roles by H2 heading. No registration step needed.
