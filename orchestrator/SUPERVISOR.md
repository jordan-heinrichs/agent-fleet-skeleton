# SUPERVISOR — Stuck detection rules

The supervisor is the agent-fleet equivalent of a watchdog timer. It runs at
the end of every fire, classifies the work produced, and halts the fleet when
it detects loops or stalls.

## Classification

Every file produced this fire gets one of four labels. The manager's bash
supervisor only tracks total file count today, but a fuller implementation
classifies each file:

| Label | Meaning |
|---|---|
| `breadth` | New file in a directory with fewer than five existing files, or covers a NEW category. |
| `depth` | Adds material to an already-covered topic. |
| `connect` | Cross-references or indexes other files; meta-files. |
| `polish` | Re-touches an existing file without expanding scope. **Red flag.** |

## Stop conditions

### HARD STOP (any one triggers `STUCK.md`)

| Signal | Threshold |
|---|---|
| Files written | 0 files across 3 consecutive fires |
| Workers aborted | 100% of workers reported "target already done" |
| Polish ratio | 100% of files this fire classified as `polish` |
| Duplicate filenames | Two workers wrote to the same path this fire |

### SOFT STOP (two or more trigger `STUCK.md`)

| Signal | Threshold |
|---|---|
| `no_breadth` | Zero `breadth` files in last 3 fires |
| `role_concentration` | One role >66% of last 3 fires |
| `polish_creep` | Polish ratio >0.6 over a 5-fire window |
| `ledger_static` | Ledger hasn't grown in 2 fires |

## When STUCK

`STUCK.md` halts the manager. Subsequent fires read it and sleep until it is
removed. To resume:

1. Inspect `SUPERVISOR_LOG.jsonl` and `WORKER_REPORTS/`
2. Optionally update `NORTH_STAR.json` to redirect focus
3. `rm orchestrator/STUCK.md`
4. Next tick the manager picks the least-represented role with reduced fleet
   size to probe whether the stall has cleared

## Why this exists

Without the supervisor, an autonomous loop can run for hours producing nothing
useful while the operator sleeps. The first hour of any fleet's life looks
identical whether it is doing real work or polish-looping. The supervisor is
the only thing that can tell those apart from inside the loop.

## Override

Operators can override the supervisor by writing
`orchestrator/UNSTUCK_DIRECTIVE.md`:

```markdown
# Unstuck directive

fleet_size: 4
forced_role: researcher
forced_targets:
  - <target slug 1>
  - <target slug 2>
ignore_supervisor_for_fires: 3
```

The manager consumes this on the next fire and deletes it after reading.

## Reference

This pattern is lifted from BitBooth's autopilot supervisor.js, generalized
for the multi-worker case.
