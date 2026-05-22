# agent-fleet-skeleton

![validate](https://github.com/Drock91/agent-fleet-skeleton/actions/workflows/ci.yml/badge.svg)
![license](https://img.shields.io/badge/license-MIT-blue.svg)

A runnable starter for an autonomous agent fleet. One driver, a few horses, and a track to run them on. Works with Claude (rides your Max plan) or fully local models via Ollama, and auto-switches between them.

Think of it like harnessing AI horses. Each worker is a horse that can pull a heavy load (one focused agent session) but a single horse alone runs in circles. The orchestrator is the driver who decides which horse goes where, the canary is the stable check before you saddle up, and the supervisor is the trainer who pulls a horse off the track when it stops pulling its weight. You provide the goal and the track. The fleet does the running.

## Prerequisites

You need two things:

1. **Docker** with Compose (Docker Desktop on macOS/Windows, or Docker Engine on Linux). That's the only hard requirement.
2. **An engine to run the agents** — pick at least one:
   - **Claude** (default, highest quality): Claude Code installed and logged in on your host, on a Claude Max plan. The fleet mounts your `~/.claude` session, so workers ride your subscription with zero per-token cost.
   - **Ollama** (free, local, no subscription): [install Ollama](https://ollama.com), then `ollama pull qwen2.5-coder:14b`. Runs on your own GPU, $0 forever.

Optional: `make` for the convenience commands below, and an SSH key if you want the fleet to auto-push its commits.

## Quick start (about 5 minutes)

```bash
git clone https://github.com/Drock91/agent-fleet-skeleton
cd agent-fleet-skeleton
cp .env.example .env          # defaults are sane; edit to pick your provider
docker compose up -d --build  # build + start the fleet
docker compose logs -f manager
```

That's it. The manager runs a canary check, picks two roles, dispatches jobs to the workers, and starts filling `packs/<active>/output/` with content.

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
manager: PICK ROLES → researcher, synthesizer
worker:  agent[<provider>:<model>] exit=0 duration=...s
```

Files appear under `packs/<active>/output/`. If you set the Ollama provider, the worker line reads `agent[ollama:...]` and not a single Claude call is made.

## The three moving parts

### 1. The canary (small model ping before each fire)

Before the manager spends real tokens on the heavy workers, it sends one cheap message to a small model (Haiku by default) and waits for a response. If the canary fails, the fleet sleeps and retries instead of dispatching jobs into a broken auth window or a rate-limited gate.

Think of it as the bell on the door of the stable. If the stable is dark or the door is jammed, you find out for the price of one penny instead of saddling up four horses and discovering it then.

You can see this in `docker/manager/entrypoint.sh` under the `canary_check` function.

### 2. The orchestrator (the driver)

The orchestrator is the manager container plus the files in `orchestrator/`. Its whole job is to answer the question "what should the next worker do, and which one should do it?"

Per tick (default every 15 minutes) the orchestrator does these things in order.

1. Run the canary
2. Read the active pack's `ROLES.md` and auto-discover every role defined there
3. Count how many times each role appears in `orchestrator/ANTI_LOOP_LEDGER.md` and prefer the ones with the lowest count, which naturally biases the fleet toward underrepresented work
4. Build a small JSON envelope per role and LPUSH it onto a Redis queue
5. Wait for the workers to push results back
6. Run the supervisor (described below) and decide if the fleet is healthy
7. Git commit everything and optionally push
8. Sleep until the next tick

The orchestrator never calls Claude itself. That keeps your token spend proportional to the worker count, not the manager's wall clock.

### 3. The workers (the horses)

Each worker container does the same simple loop forever.

1. Block on `BRPOP fleet:jobs` waiting for an envelope
2. When one arrives, build a long prompt that includes the role brief from `ROLES.md`, the pack's targets from `TARGETS.md`, and the recent tail of the anti-loop ledger so the worker knows what is already done
3. Spawn a headless `claude --print` with that prompt
4. After Claude exits, count how many new files appeared in the workspace via a `find` diff
5. LPUSH a result envelope back to Redis so the manager can collect it
6. Loop

Workers write straight to the bind-mounted workspace, so anything Claude produces lands on the host filesystem in real time. The manager picks it up at the end of the fire and commits it.

**A note on `--dangerously-skip-permissions`:** Claude CLI requires this flag to run non-interactively — it cannot be removed. The blast radius is limited structurally: `orchestrator/` is mounted read-only inside every worker container, so a misbehaving or injected worker cannot overwrite `NORTH_STAR.json`, the ledger, or the entrypoint scripts. Workers can only write to `packs/<name>/` and their own temp files.

## Choosing your LLM provider

The fleet is model-agnostic. The engine (canary, ledger, supervisor, rotation, Redis bus) never changes; only the leaf call that runs the agent swaps behind an adapter. Two providers ship in the box.

| Provider | Cost | Quality | Notes |
|---|---|---|---|
| `claude` | $0 per token on Claude Max (flat subscription) | highest | Default. Rides your mounted `~/.claude` OAuth session. Rate-limited by the Max usage window. |
| `ollama` | $0 forever, no subscription | scales with your GPU | Local models via Aider. Install Ollama on the host and `ollama pull <model>` first. No rate window. |

Set the provider in `.env`:

```bash
# pure local, zero cost
AGENT_PROVIDER=ollama
AGENT_MODEL=qwen2.5-coder:14b
```

### The fallback switch (so the fleet never stops)

The most useful setup is Claude for quality with a local fallback. When Claude Max hits its cooldown window, the worker retries the same job on Ollama instead of sleeping — so the fleet keeps producing on your own hardware until Max comes back.

```bash
AGENT_PROVIDER=claude
AGENT_MODEL=claude-sonnet-4-7
AGENT_FALLBACK=ollama
FALLBACK_MODEL=qwen2.5-coder:14b
```

In the worker logs you'll see the handoff:

```
agent[claude:claude-sonnet-4-7] exit=1 duration=9s
primary (claude) walled — falling back to ollama:qwen2.5-coder:14b
agent[ollama:qwen2.5-coder:14b] exit=0 duration=210s
```

### Adding another provider

Drop a `docker/adapters/<name>.sh` defining `<name>_run_agent`, `<name>_run_canary`, and `<name>_exhaustion_regex`. The dispatcher auto-discovers it — no registration. An Aider-backed adapter can route to GPT, Gemini, or DeepSeek with the same shape.

## The three-phase workflow

This skeleton is generic on purpose. You can wire it up to do almost anything but the most productive pattern in practice is a three-phase pipeline. Each phase is a worker role you define.

### Phase 1, gather information

Your first role is a researcher. It reads `TARGETS.md`, picks one target that is not yet in the anti-loop ledger, does the legwork (web search, document fetching, code inspection), and writes one structured findings file under `packs/<pack>/output/findings/`. Run this phase until the findings directory is dense.

The skeleton ships with a `researcher` role you can use as is or modify.

### Phase 2, develop solutions

Your second role is a synthesizer or solution architect. It reads what the researcher produced, looks across multiple findings for patterns, and writes proposal documents under `packs/<pack>/output/solutions/`. Each solution document references the findings it draws from, explains the problem it solves, and outlines the design.

The skeleton ships with a `synthesizer` role as a starting point. Rename or rewrite the brief to focus on producing solution proposals rather than generic syntheses.

### Phase 3, implement those solutions

Your third role is an implementer. It reads a solution document, scaffolds the actual code or configuration or content the solution describes, and writes it under `packs/<pack>/output/implementations/`. This is where the fleet stops talking about the problem and starts producing the artifact that solves it.

The implementer role is not in the skeleton yet because what counts as an implementation depends on what you are building. Add it to `ROLES.md` with a clear brief and the manager will auto-pick it up on the next fire.

### Why three phases works

Each phase produces stable input for the next. Researcher writes a findings file, synthesizer reads it, synthesizer writes a solution file, implementer reads it. The anti-loop ledger keeps any phase from re-doing work that was already done. The supervisor halts the fleet if any phase stops producing breadth, which is your early warning that you have either run out of targets or your role briefs need tightening.

You can run all three phases in parallel within one fleet by listing all three roles in `ROLES.md`. The orchestrator will rotate through them, biased toward whichever phase has the fewest entries in the ledger. Early on this means lots of phase 1. Once findings stack up the rotation naturally tilts toward phase 2. Once solutions exist the rotation naturally tilts toward phase 3. The fleet self-balances without you having to schedule anything.

## How the supervisor catches problems

Autonomous agent loops have two famous failure modes. Either they slide into a polish loop where they keep refining the same files instead of producing new ones, or they drift off scope and start producing material that has nothing to do with the goal. The supervisor is the thing that catches both.

After every fire it does these checks.

- Did any new files get written this fire? If three fires in a row produce zero new files the supervisor writes `orchestrator/STUCK.md` and the next fire halts.
- Is the same role being picked over and over? More than three fires in a row with the same role triggers a warning.
- Is the polish ratio creeping up? When more than 60 percent of fires across a sliding window classify as polish rather than breadth, the supervisor halts.

When the supervisor writes `STUCK.md` the operator looks at `SUPERVISOR_LOG.jsonl` and the per-fire reports under `orchestrator/WORKER_REPORTS/`, decides what changed, and removes `STUCK.md` to resume.

You can read the full rules in `orchestrator/SUPERVISOR.md`.

## Topic packs — make it yours (the plugin system)

The engine is domain-agnostic. Everything topic-specific lives in a **pack** — a drop-in plugin folder under `packs/`:

```
packs/<topic>/
  pack.env      config: name, output dir, web-grounding on/off, preferred search domains
  ROLES.md      specialist roles (each with a **Search:** query + **Output:** dir)
  TARGETS.md    the domain's sources/targets
  output/       where workers write (created on first run)
```

Two ship in the box: `example-research` (generic template) and `web3-security` (a real, filled-in example with web grounding on).

**Make a pack for your own topic in 3 steps:**

```bash
cp -r packs/example-research packs/my-topic
# 1. edit packs/my-topic/ROLES.md     — your specialist roles + search queries
# 2. edit packs/my-topic/TARGETS.md   — your sources
# 3. set ACTIVE_PACK=my-topic in .env, then: docker compose up -d --build
```

Swap `ACTIVE_PACK` and the entire fleet retargets — same orchestrator, workers, manager, Redis cache, provider adapters, and web grounding, pointed at a brand-new domain. That's the whole plugin model.

## Other knobs

| Setting | What it does |
|---|---|
| `.env` `ACTIVE_PACK` | Which topic pack the fleet runs. |
| `.env` `AGENT_PROVIDER` / `AGENT_FALLBACK` | Engine (claude / ollama) + auto-fallback. |
| pack `pack.env` `WEB_GROUNDING` | Turn the cached SearXNG web-research step on/off for that pack. |
| pack `pack.env` `SEARCH_PREFERRED_DOMAINS` | High-authority sources to rank first for your topic. |
| `.env` `CACHE_TTL` / `REDIS_MAXMEMORY` | Research cache lifetime + size (volatile-lru eviction). |
| `orchestrator/NORTH_STAR.json` | The fleet's stated goal (read by the supervisor). |

## Troubleshooting

**Manager logs say `canary FAILED`.** Your Claude Max session expired or hit a rate limit. The manager will sleep and retry on its own. If it persists for more than a couple of cycles, check `docker compose logs manager` for the actual error text and confirm your host can run `claude` directly.

**Workers are running but no files appear.** Check `orchestrator/WORKER_REPORTS/` for the per-fire result envelopes. `status: no_files_written` means Claude ran but produced nothing, usually because the role brief is too vague or the targets are already exhausted. `status: fast_fail` means Claude exited in under 60 seconds. That is almost always either a Max-plan throttle (the worker sleeps it off and retries) or an invalid `AGENT_MODEL` string for your plan (fix it in `.env` and rebuild). The `extra` field in the result envelope usually shows which.

**Fleet wrote `STUCK.md`.** Read it. Read the supervisor log. Decide if you need new targets, a new role, or just to remove `STUCK.md` and retry.

**Files show up with wrong ownership.** The Dockerfiles use `ARG USER_UID` and `USER_GID` from the host. Pass `UID=$(id -u) GID=$(id -g)` to `docker compose` or set them in `.env`.

## Architecture diagram

See `docs/architecture.md` for the full per-tick flow and the auth model. Short version of the data flow:

```
manager  ── LPUSH job ──>  redis  <── BRPOP ── worker N
manager  <── BRPOP result ── redis  <── LPUSH ── worker N
                                            │
                                            ↓
                                  writes files into ./packs/<name>/
                                            │
                                            ↓
                            manager commits + optionally pushes
```

## Credit

Architecture lineage is the BitBooth autopilot pattern (Drock91), split into a multi-container fleet for the multi-agent case. License is MIT, do whatever you want with it.
