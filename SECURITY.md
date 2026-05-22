# Security

This is a skeleton meant to be forked and customized, but it runs autonomous
agents with real tool access, so a few things are worth understanding before
you point it at anything that matters.

## Threat model in one paragraph

Workers run `claude --dangerously-skip-permissions`, which gives the model
unrestricted tool access inside its container. That flag cannot be removed —
the Claude CLI requires it to run non-interactively. So the design assumes a
worker could do anything its container allows, and bounds what the container
allows.

## Containment measures already in place

- **`orchestrator/` is mounted read-only in every worker container.** A
  worker cannot overwrite `NORTH_STAR.json`, the anti-loop ledger, the
  supervisor rules, or any entrypoint script, even with full tool access. The
  manager is the single writer of everything under `orchestrator/`. (Finding
  C-01.)

- **Ledger input is sanitized before it reaches a prompt.** The worker strips
  any line from the ledger tail that does not match the canonical format
  `^- .+ ← [a-z-]+ \(fire #[0-9]+\)$` before embedding it. This blocks an
  injected instruction in the ledger from propagating into subsequent worker
  prompts. (Finding C-02.)

- **Workers can only write to `packs/<active>/output/`** and their own temp files.

- **The canary uses a cheap model and a short timeout**, so a broken or
  hostile auth state is detected before a full fire's worth of tokens is
  spent.

## What is NOT hardened (know before you scale)

- The bind mount maps your real repo into the containers. A worker can write
  anywhere under the pack output dir. If you point the fleet at a sensitive
  repository, scope the mount accordingly.
- The fleet mounts your host `~/.claude` credentials. Anyone who can exec
  into a worker container can read them. Run this on a machine you trust.
- The `.env` is gitignored, but double-check you never commit one with an
  `ANTHROPIC_API_KEY` in it. The example file leaves it commented out on
  purpose.
- The path field in a ledger line is still free text that matches `.+`.
  Tightening it to `[A-Za-z0-9._/-]+` closes a residual injection sliver if
  your project produces attacker-influenced filenames.

## Reporting

This is an early-stage project. If you find a containment gap, open an issue
or a PR. Security findings that improve the containment posture are the most
welcome kind of contribution.
