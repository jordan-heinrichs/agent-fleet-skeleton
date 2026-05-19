# agent-fleet-skeleton

A minimal, runnable starter for an autonomous Claude agent fleet. One manager
container, two worker containers, a Redis queue, a north star, an anti-loop
ledger, and a supervisor that halts the fleet when it starts polishing instead
of producing.

Rides the host's Claude Max subscription via OAuth, so the workers cost zero
dollars in API spend while you iterate.

## What you can build with this

Anything that benefits from many agents working in parallel on a shared goal.
Examples that are within scope of this skeleton out of the box:

- Continuous research libraries (corpus building over weeks)
- Codebase-wide refactor sweeps
- Continuous dependency review or supply-chain monitoring
- Long-horizon document generation with cross-file consistency
- Periodic data scraping and curation pipelines

The architecture is goal-agnostic. You provide the goal (`orchestrator/NORTH_STAR.json`),
the worker roles (`orchestrator/WORKER_ROLES.md`), and the target inputs
(`projects/<name>/PROJECT_TARGETS.md`). The fleet handles the rest.

## Quick start

```bash
# 1. Clone
git clone https://github.com/<you>/agent-fleet-skeleton
cd agent-fleet-skeleton

# 2. Configure
cp .env.example .env
# (Optional) edit .env to change tick interval, model, etc.

# 3. Boot
docker compose up -d --build

# 4. Watch
docker compose logs -f manager
```

The manager runs a canary check with a small model (`claude-haiku-4-5`) before
spending tokens on the main workers. If the canary fails (rate limit, auth,
network), it sleeps and retries instead of dispatching jobs into a closed gate.

## Architecture

```
              ┌──────────────┐
              │   manager    │  picks a role + target every TICK_INTERVAL,
              │ (1 replica)  │  LPUSHes jobs to Redis, supervises results
              └──────┬───────┘
                     │
                     ▼
              ┌──────────────┐
              │    redis     │  job + result queue
              └──────┬───────┘
                     ▲
         ┌───────────┴───────────┐
         │                       │
    ┌────┴────┐             ┌────┴────┐
    │ worker  │             │ worker  │  BRPOP a job, run claude --print
    │  #1     │             │  #2     │  with the role brief, write outputs
    └─────────┘             └─────────┘  to the bind-mounted workspace
```

## Why the supervisor exists

A naive agent loop will drift into what the BitBooth project calls a "polish
loop." It reruns lint, regenerates the same docs, and looks busy without
producing anything new. Read `orchestrator/NORTH_STAR.md` for the full
philosophy. Short version: the supervisor classifies every fire as
`breadth | depth | connect | polish` and halts the fleet when polish ratio
crosses a threshold.

## Mono-repo style

Each subproject under `projects/` is self-contained. Add a new directory,
drop a `PROJECT_TARGETS.md` in it, point the manager at it via env, and the
fleet rotates through that project's targets. You can run many projects from
one fleet by extending the manager's project picker.

## Where to start customizing

| File | What to change |
|---|---|
| `orchestrator/NORTH_STAR.json` | What you're actually trying to achieve |
| `orchestrator/WORKER_ROLES.md` | Add or remove specialist roles |
| `projects/example-project/PROJECT_TARGETS.md` | The targets your roles consume |
| `.env` | Tick interval, fleet size, model, branch |

## What this doesn't do

It is a skeleton, not a product. Out of the box it has two example roles
(`researcher` and `synthesizer`) and one example project. The point is for
you to swap those out for your own.

## Credit

Architecture lineage: BitBooth autopilot (Drock91), heavily simplified for
the skeleton case.

License: MIT
