# orchestrator/

The brain. Five files plus a log.

| File | What it does |
|---|---|
| `NORTH_STAR.md` | Philosophy. Why this directory exists. Read it once when you set up the fleet, then probably never again. |
| `NORTH_STAR.json` | Machine-readable goal + coverage state. Workers read it for context. Only the manager writes to it. |
| `WORKER_ROLES.md` | Per-role briefs. The manager auto-discovers roles by H2 heading. Add or remove roles by editing this file. |
| `ANTI_LOOP_LEDGER.md` | Append-only done-list. Workers grep before picking work; the manager counts entries per role to drive rotation. |
| `SUPERVISOR.md` | Stuck-detection rules. The supervisor halts the fleet when polish ratio crosses threshold or zero-file fires accumulate. |
| `SUPERVISOR_LOG.jsonl` | One JSON line per fire with the supervisor's verdict. Used by `check_stuck` to detect three-fire stalls. |

## Runtime-only files (gitignored)

| File | What it does |
|---|---|
| `STUCK.md` | If present, the manager halts ticks until it is removed. The supervisor writes it when stop conditions trigger. |
| `STUCK_LOG/` | Archive of past stuck markers. |
| `WORKER_REPORTS/fire-N-<role>.json` | Per-fire raw worker results. Useful for forensics when something looks off. |
| `INTERVAL` | Optional override for tick interval. Useful if you wire up a dashboard. |
| `FLEET_SIZE` | Optional override for worker count. Same. |

## How to extend

Add a new role: append an H2 section to `WORKER_ROLES.md` with the standard
shape. The manager picks it up on the next fire without restarting.

Add a new project: create `projects/<name>/PROJECT_TARGETS.md` and set
`ACTIVE_PROJECT=<name>` in `.env`. Rebuild manager+workers.

Change the goal: edit `NORTH_STAR.json`. Next fire reflects it.
