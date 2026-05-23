# agent-fleet-skeleton

![validate](https://github.com/Drock91/agent-fleet-skeleton/actions/workflows/ci.yml/badge.svg)
![license](https://img.shields.io/badge/license-MIT-blue.svg)

A runnable starter for an autonomous agent fleet. One driver, a few horses, and a track to run them on. Works with Claude (rides your Max plan) or fully local models via Ollama, and auto-switches between them.

Think of it like harnessing AI horses. Each worker is a horse that can pull a heavy load (one focused agent session) but a single horse alone runs in circles. The orchestrator is the driver who decides which horse goes where, the canary is the stable check before you saddle up, and the supervisor is the trainer who pulls a horse off the track when it stops pulling its weight. You provide the goal and the track. The fleet does the running.

## What it is

A small, self-contained system that runs a team of AI agents in a loop, on a schedule, against a goal you define, with no human in the seat between fires. A manager container wakes on a timer, checks that the model is reachable, hands one focused job to each worker, collects what they produce, records it so the next round does not repeat it, and commits the result. Everything topic-specific lives in a drop-in **pack**, so the same engine can research smart-contract bugs today and summarize case law tomorrow by swapping one folder.

It is deliberately small. The whole engine is a few bash scripts, a Redis queue, and a Docker Compose file. There is no framework to learn and nothing hidden. You can read the entire thing in an afternoon.

## Built for a security lab

This is not a toy. It is the harness behind a working Web3 security lab, where the fleet runs continuously to mine known exploit classes, catalog real incidents, draft defensive patterns, and produce reference implementations of the fixes. The three-phase pattern below (research, then design, then implement) is exactly how that lab turns a vague "go study reentrancy" into a folder of concrete, reviewed artifacts.

The skeleton in this repo is that harness with the lab's private packs removed and a tiny public demo pack left in its place, so you can see the machine run end to end and then point it at your own domain.

## What it can do

- **Run agents unattended, for hours or days.** The manager fires on a timer, so the fleet keeps producing while you sleep. Token spend is proportional to worker count, not wall-clock time.
- **Run on Claude, on local models, or both.** A provider adapter layer means the engine never changes. Use Claude for depth, Ollama for $0 local generation, or Claude-with-Ollama-fallback so the fleet never stops when the Max window cools down.
- **Retarget to any topic without touching the engine.** Write a pack (`ROLES.md`, `TARGETS.md`, `pack.env`), set `ACTIVE_PACK`, and the whole fleet points at the new domain.
- **Avoid going in circles.** An anti-loop ledger records every file produced so later fires pick fresh work, and a supervisor halts the fleet when it stops producing breadth or drifts off scope.
- **Ground its work in real sources (optional).** A per-pack web-grounding step fetches and caches real pages through a self-hosted search engine, so models cite real URLs instead of inventing them.
- **Stay cheap and recoverable.** Output lands on the host filesystem in real time and is committed every fire, so a crash never loses more than the current round.

## What it can't do (by design, and honest limits)

- **It is not a chat agent.** There is no conversation, no human-in-the-loop approval per step. You set the goal and the guardrails up front, then it runs on its own. That is the point, and it means a bad role brief produces a lot of bad output before you notice.
- **Output quality tracks the model.** On Claude the documents are deep and well-sourced. On a local 14B coder model they are solid and correct but shorter and plainer. Local long-form research is the weakest case; local code generation is the strongest. Pick the model to match the phase.
- **Local throughput is bound by your GPU.** All workers share one Ollama server, so on a single GPU local jobs effectively serialize. More workers help on Claude (parallel) far more than on local models.
- **File attribution under parallel writes is approximate.** When several workers write to the same pack output directory in one fire, the per-worker "new files" count can include a sibling's file. The deliverables are correct; the bookkeeping is fuzzy. The ledger is deduplicated by path.
- **It does not manage secrets or deploy anything.** It writes files and commits them. Pushing, deploying, and reviewing are still yours.
- **It will not invent a model for you.** If `AGENT_MODEL` is wrong for your plan or install, the worker fast-fails in seconds. Use an alias like `sonnet` for Claude, or a tag from `ollama list`.

## Prerequisites

You need two things:

1. **Docker** with Compose (Docker Desktop on macOS/Windows, or Docker Engine on Linux). That is the only hard requirement.
2. **An engine to run the agents** — pick at least one:
   - **Claude** (default, highest quality): Claude Code installed and logged in on your host, on a Claude Max plan. The fleet mounts your `~/.claude` session, so workers ride your subscription with zero per-token cost.
   - **Ollama** (free, local, no subscription): [install Ollama](https://ollama.com), then `ollama pull qwen2.5-coder:14b`. Runs on your own GPU, $0 forever.

Optional: `make` for the convenience commands below, and an SSH key if you want the fleet to auto-push its commits.

## Quick start (about 5 minutes)

```bash
git clone https://github.com/Drock91/agent-fleet-skeleton
cd agent-fleet-skeleton
bash setup.sh                 # creates .env + the host mount placeholders
docker compose up -d --build  # build + start the fleet
docker compose logs -f manager
```

`setup.sh` is safe to re-run. It copies `.env.example` to `.env` if you don't have one, and creates empty `~/.claude`, `~/.claude.json`, and `~/.ssh` placeholders so the Docker mounts resolve even if you only plan to use Ollama and have never installed Claude. Claude users already have these and the script leaves them untouched.

By default the fleet uses Claude. If you want the free local path instead, set `AGENT_PROVIDER=ollama` and `AGENT_MODEL=qwen2.5-coder:14b` in `.env` before starting (and make sure Ollama is running with that model pulled).

That's it. The manager runs a canary check, picks roles from the active pack, dispatches jobs to the workers, and starts filling `packs/<active>/output/` with content.

### Or with `make` (macOS/Linux convenience)

```bash
make doctor   # check your prerequisites first
make up       # creates .env if missing, builds, starts
make logs     # follow the manager
make status   # container status + recent fires
make clean    # stop + wipe generated output
make down     # stop everything
```

### Verify it's working

```
manager: canary: ... OK
manager: PICK ROLES → researcher, solution-architect, implementer
worker:  agent[<provider>:<model>] exit=0 duration=...s
```

Files appear under `packs/<active>/output/`. If you set the Ollama provider, the worker line reads `agent[ollama:...]` and not a single Claude call is made.

## Worked example: fixing a reentrancy bug

The repo ships with a small three-phase pack, `reentrancy-fix-demo`, that takes one well-known smart-contract bug from explanation to fix. It is the fastest way to watch the whole machine work, and it runs on both providers.

The target is the classic reentrancy hole: a vault whose `withdraw()` sends ETH **before** zeroing the caller's balance. Three roles, one per phase:

1. **researcher** explains the vulnerability and the real incidents that used it (e.g. The DAO, 2016) → `output/research/`
2. **solution-architect** designs the fix across the three standard defenses (Checks-Effects-Interactions, a reentrancy guard, pull-over-push) → `output/solutions/`
3. **implementer** writes the corrected, compilable Solidity → `output/implementations/`

Run it:

```bash
# in .env
ACTIVE_PACK=reentrancy-fix-demo
AGENT_PROVIDER=claude       # or: ollama
AGENT_MODEL=sonnet          # or: qwen2.5-coder:14b
FLEET_SIZE=3

docker compose up -d --build
```

One fire produces all three documents. Verified on both providers:

| Phase | File | Claude (`sonnet`) | Ollama (`qwen2.5-coder:14b`, local, $0) |
|---|---|---|---|
| 1. research | `research/reentrancy-explained.md` | 189 lines | 65 lines |
| 2. design | `solutions/reentrancy-fix-design.md` | 192 lines | 115 lines |
| 3. implement | `implementations/SafeVault.md` | 93 lines | 42 lines |

Both providers produced correct, on-target work: a real explanation of the re-entry sequence, a design that names all three defenses with rationale, and Solidity that applies Checks-Effects-Interactions plus OpenZeppelin's `nonReentrant`. Claude's output is deeper and more thoroughly sourced; the local model's is shorter but technically correct, at zero cost.

Real generated output from both runs is checked in under [`packs/reentrancy-fix-demo/sample-output/`](packs/reentrancy-fix-demo/sample-output/), and the pack itself is documented in [`packs/reentrancy-fix-demo/README.md`](packs/reentrancy-fix-demo/README.md).

## How it works

### The canary (a cheap ping before each fire)

Before the manager spends real work on the heavy workers, it sends one tiny message to a small model (Haiku for Claude, a one-token generation for Ollama) and waits for a response. If the canary fails, the fleet sleeps and retries instead of dispatching jobs into a broken auth window or a rate-limited gate.

It is the bell on the stable door. If the door is jammed you find out for the price of one penny instead of saddling four horses and discovering it then. See `canary_check` in `docker/manager/entrypoint.sh`.

### The orchestrator (the driver)

The orchestrator is the manager container plus the files in `orchestrator/`. Its whole job is to answer "what should the next worker do, and which one should do it?" Per tick (default every 15 minutes) it:

1. Runs the canary.
2. Reads the active pack's `ROLES.md` and auto-discovers every role defined there.
3. Counts how many times each role appears in `orchestrator/ANTI_LOOP_LEDGER.md` and prefers the ones with the lowest count, which biases the fleet toward underrepresented work.
4. Builds a small JSON job per role and LPUSHes it onto a Redis queue.
5. Waits for the workers to push results back.
6. Runs the supervisor and decides whether the fleet is healthy.
7. Commits everything and optionally pushes.
8. Sleeps until the next tick.

The orchestrator never calls a model itself. That keeps spend proportional to worker count, not the manager's wall clock.

### The workers (the horses)

Each worker container runs the same loop forever:

1. Block on `BRPOP fleet:jobs` waiting for a job.
2. Build a prompt from the role brief (`ROLES.md`), the pack targets (`TARGETS.md`), and the recent tail of the anti-loop ledger so it knows what is already done.
3. Run the agent through the provider adapter. For Claude that is a headless `claude --print`; for Ollama it is a direct generation against the local server, and the worker writes the returned document to the role's output file itself.
4. Count new files in the pack's output directory via a `find` diff.
5. LPUSH a result envelope back to Redis for the manager to collect.
6. Loop.

Workers write straight to the bind-mounted workspace, so output lands on the host in real time and the manager commits it at the end of the fire.

**On `--dangerously-skip-permissions`:** the Claude CLI requires this flag to run non-interactively; it cannot be removed. The blast radius is limited structurally. `orchestrator/` is mounted read-only inside every worker, so a misbehaving or injected worker cannot overwrite `NORTH_STAR.json`, the ledger, or the entrypoints. Workers can only write under `packs/<name>/`.

### The supervisor (catches the two failure modes)

Autonomous loops fail two ways: they slide into a polish loop, refining the same files instead of making new ones, or they drift off scope. After every fire the supervisor checks:

- **Zero-file fires.** Three in a row writes `orchestrator/STUCK.md` and the next fire halts.
- **Same role over and over.** More than three consecutive fires on one role triggers a warning.
- **Polish creep.** When more than 60% of fires in a sliding window are polish rather than breadth, it halts.

When `STUCK.md` appears, read it and `SUPERVISOR_LOG.jsonl`, decide what changed, remove `STUCK.md`, and resume. Full rules in `orchestrator/SUPERVISOR.md`.

## Providers: Claude and Ollama

The fleet is model-agnostic. The engine (canary, ledger, supervisor, rotation, Redis bus) never changes; only the leaf call that runs the agent swaps behind an adapter in `docker/adapters/`. Two ship in the box.

| Provider | Cost | Quality | How it runs the agent |
|---|---|---|---|
| `claude` | $0 per token on Claude Max (flat subscription) | highest | Headless `claude --print` on your mounted `~/.claude` session. Rate-limited by the Max window. |
| `ollama` | $0 forever, no subscription | scales with your GPU | Direct generation against a host-run Ollama server; the worker writes the returned document. No rate window. |

Set the provider in `.env`:

```bash
# pure local, zero cost
AGENT_PROVIDER=ollama
AGENT_MODEL=qwen2.5-coder:14b
```

Use an alias (`sonnet`, `opus`, `haiku`) for Claude so the string always resolves to a current model. A worker that fast-fails a few seconds after boot almost always means a wrong `AGENT_MODEL`.

### The fallback switch (so the fleet never stops)

The most useful setup is Claude for quality with a local fallback. When Claude Max hits its cooldown window, the worker rebuilds the prompt for the fallback provider and retries the same job on Ollama instead of sleeping, so the fleet keeps producing on your own hardware until Max comes back.

```bash
AGENT_PROVIDER=claude
AGENT_MODEL=sonnet
AGENT_FALLBACK=ollama
FALLBACK_MODEL=qwen2.5-coder:14b
```

In the worker logs you'll see the handoff:

```
agent[claude:sonnet] exit=1 duration=9s
primary (claude) walled — falling back to ollama:qwen2.5-coder:14b
agent[ollama:qwen2.5-coder:14b] exit=0 duration=210s
```

### Adding another provider

Drop a `docker/adapters/<name>.sh` defining `<name>_run_agent`, `<name>_run_canary`, and `<name>_exhaustion_regex`. The dispatcher auto-discovers it; there is no registration step.

## The three-phase workflow

The engine is generic, but the most productive pattern is a three-phase pipeline, with each phase a worker role you define. The `reentrancy-fix-demo` pack above is a complete, working instance of it.

1. **Gather (researcher).** Reads `TARGETS.md`, picks a target not yet in the ledger, does the legwork, and writes one structured findings file under `output/research/` (or `output/findings/`, your choice).
2. **Design (solution-architect).** Reads the research, finds the pattern, and writes a proposal under `output/solutions/` that references the findings it draws from.
3. **Implement (implementer).** Reads a solution and produces the actual artifact (code, config, contract) under `output/implementations/`.

**Why three phases works.** Each phase produces stable input for the next, and the ledger keeps any phase from redoing finished work. List all three roles in `ROLES.md` and the orchestrator self-balances: lots of phase 1 early, tilting to phase 2 as research stacks up, then to phase 3 once solutions exist. You schedule nothing.

## Topic packs — make it your own (the plugin system)

Everything topic-specific lives in a **pack**, a drop-in folder under `packs/`:

```
packs/<topic>/
  pack.env      config: name, output dir, web-grounding on/off, preferred search domains
  ROLES.md      specialist roles (each with a **Search:** query + **Output:** dir)
  TARGETS.md    the domain's sources/targets
  output/       where workers write (created on first run)
```

Three ship in the box: `example-research` (generic template), `web3-security` (a filled-in example with web grounding), and `reentrancy-fix-demo` (the three-phase worked example above).

**Make a pack for your own topic in three steps:**

```bash
cp -r packs/example-research packs/my-topic
# 1. edit packs/my-topic/ROLES.md     — your specialist roles + search queries
# 2. edit packs/my-topic/TARGETS.md   — your sources
# 3. set ACTIVE_PACK=my-topic in .env, then: docker compose up -d --build
```

Swap `ACTIVE_PACK` and the entire fleet retargets, same orchestrator, workers, manager, Redis cache, provider adapters, and web grounding, pointed at a brand-new domain. That is the whole plugin model.

## Other knobs

| Setting | What it does |
|---|---|
| `.env` `ACTIVE_PACK` | Which topic pack the fleet runs. |
| `.env` `AGENT_PROVIDER` / `AGENT_FALLBACK` | Engine (claude / ollama) + auto-fallback. |
| `.env` `AGENT_MODEL` / `FALLBACK_MODEL` | Worker model per provider (alias for Claude, tag for Ollama). |
| `.env` `FLEET_SIZE` / `TICK_INTERVAL_MINUTES` | How many workers, how often the manager fires. |
| pack `pack.env` `WEB_GROUNDING` | Turn the cached SearXNG web-research step on/off for that pack. |
| pack `pack.env` `SEARCH_PREFERRED_DOMAINS` | High-authority sources to rank first for your topic. |
| `.env` `CACHE_TTL` / `REDIS_MAXMEMORY` | Research cache lifetime + size (volatile-lru eviction; the job queue is never evicted). |
| `orchestrator/NORTH_STAR.json` | The fleet's stated goal (read by the supervisor). |

## Troubleshooting

**Manager logs say `canary FAILED`.** For Claude, your Max session expired or hit a rate limit; the manager sleeps and retries. If it persists, check `docker compose logs manager` and confirm your host can run `claude` directly. For Ollama, confirm the server is up (`ollama list`) and reachable at `OLLAMA_API_BASE`.

**Workers run but no files appear.** Check `orchestrator/WORKER_REPORTS/` for the per-fire envelopes. `status: no_files_written` means the agent ran but produced nothing usable, usually a too-vague role brief or exhausted targets. `status: fast_fail` means the agent exited in under 60 seconds, almost always a wrong `AGENT_MODEL` string (fix it in `.env`, then rebuild) or a provider throttle (the worker sleeps it off). The `extra` field usually shows which.

**Fleet wrote `STUCK.md`.** Read it, read the supervisor log, decide if you need new targets, a new role, or just to remove `STUCK.md` and retry.

**`docker compose up` hangs.** Usually a wedged Docker daemon, not the fleet. Clear stuck `docker compose` clients and restart Docker, then `docker compose up -d` again.

**Files show up with wrong ownership.** The Dockerfiles take `ARG USER_UID` / `USER_GID` from the host. Pass `UID=$(id -u) GID=$(id -g)` to `docker compose` or set them in `.env`.

## Architecture diagram

See `docs/architecture.md` for the full per-tick flow and the auth model. Short version of the data flow:

```
manager  ── LPUSH job ──>  redis  <── BRPOP ── worker N
manager  <── BRPOP result ── redis  <── LPUSH ── worker N
                                            │
                                            ↓
                                  writes files into ./packs/<name>/output/
                                            │
                                            ↓
                            manager commits + optionally pushes
```

## Credit

Architecture lineage is the BitBooth autopilot pattern (Drock91), split into a multi-container fleet for the multi-agent case. License is MIT, do whatever you want with it.
