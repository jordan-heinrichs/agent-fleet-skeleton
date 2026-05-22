# agent-fleet-skeleton

A runnable starter for an autonomous Claude agent fleet. One driver, a few horses, and a track to run them on.

Think of it like harnessing AI horses. Each worker is a horse that can pull a heavy load (one focused Claude session) but a single horse alone runs in circles. The orchestrator is the driver who decides which horse goes where, the canary is the stable check before you saddle up, and the supervisor is the trainer who pulls a horse off the track when it stops pulling its weight. You provide the goal and the track. The fleet does the running.

It rides your host's Claude Max subscription via OAuth, so the workers cost zero dollars in API spend while you iterate.

## Quick start (about 5 minutes)

```bash
# 1. clone
git clone https://github.com/Drock91/agent-fleet-skeleton
cd agent-fleet-skeleton

# 2. configure
cp .env.example .env
# open .env and skim it. Defaults are sane.

# 3. boot
docker compose up -d --build

# 4. watch the manager
docker compose logs -f manager
```

That's it. The manager will run a canary check, pick two roles, dispatch jobs to the workers, and start filling `projects/example-project/findings/` with content.

## The three moving parts

### 1. The canary (small model ping before each fire)

Before the manager spends real tokens on the heavy workers, it sends one cheap message to a small model (Haiku by default) and waits for a response. If the canary fails, the fleet sleeps and retries instead of dispatching jobs into a broken auth window or a rate-limited gate.

Think of it as the bell on the door of the stable. If the stable is dark or the door is jammed, you find out for the price of one penny instead of saddling up four horses and discovering it then.

You can see this in `docker/manager/entrypoint.sh` under the `canary_check` function.

### 2. The orchestrator (the driver)

The orchestrator is the manager container plus the files in `orchestrator/`. Its whole job is to answer the question "what should the next worker do, and which one should do it?"

Per tick (default every 15 minutes) the orchestrator does these things in order.

1. Run the canary
2. Read `orchestrator/WORKER_ROLES.md` and auto-discover every role defined there
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
2. When one arrives, build a long prompt that includes the role brief from `WORKER_ROLES.md`, the project's targets from `PROJECT_TARGETS.md`, and the recent tail of the anti-loop ledger so the worker knows what is already done
3. Spawn a headless `claude --print` with that prompt
4. After Claude exits, count how many new files appeared in the workspace via a `find` diff
5. LPUSH a result envelope back to Redis so the manager can collect it
6. Loop

Workers write straight to the bind-mounted workspace, so anything Claude produces lands on the host filesystem in real time. The manager picks it up at the end of the fire and commits it.

**A note on `--dangerously-skip-permissions`:** Claude CLI requires this flag to run non-interactively — it cannot be removed. The blast radius is limited structurally: `orchestrator/` is mounted read-only inside every worker container, so a misbehaving or injected worker cannot overwrite `NORTH_STAR.json`, the ledger, or the entrypoint scripts. Workers can only write to `projects/<name>/` and their own temp files.

## The three-phase workflow

This skeleton is generic on purpose. You can wire it up to do almost anything but the most productive pattern in practice is a three-phase pipeline. Each phase is a worker role you define.

### Phase 1, gather information

Your first role is a researcher. It reads `PROJECT_TARGETS.md`, picks one target that is not yet in the anti-loop ledger, does the legwork (web search, document fetching, code inspection), and writes one structured findings file under `projects/<project>/findings/`. Run this phase until the findings directory is dense.

The skeleton ships with a `researcher` role you can use as is or modify.

### Phase 2, develop solutions

Your second role is a synthesizer or solution architect. It reads what the researcher produced, looks across multiple findings for patterns, and writes proposal documents under `projects/<project>/solutions/`. Each solution document references the findings it draws from, explains the problem it solves, and outlines the design.

The skeleton ships with a `synthesizer` role as a starting point. Rename or rewrite the brief to focus on producing solution proposals rather than generic syntheses.

### Phase 3, implement those solutions

Your third role is an implementer. It reads a solution document, scaffolds the actual code or configuration or content the solution describes, and writes it under `projects/<project>/implementations/`. This is where the fleet stops talking about the problem and starts producing the artifact that solves it.

The implementer role is not in the skeleton yet because what counts as an implementation depends on what you are building. Add it to `WORKER_ROLES.md` with a clear brief and the manager will auto-pick it up on the next fire.

### Why three phases works

Each phase produces stable input for the next. Researcher writes a findings file, synthesizer reads it, synthesizer writes a solution file, implementer reads it. The anti-loop ledger keeps any phase from re-doing work that was already done. The supervisor halts the fleet if any phase stops producing breadth, which is your early warning that you have either run out of targets or your role briefs need tightening.

You can run all three phases in parallel within one fleet by listing all three roles in `WORKER_ROLES.md`. The orchestrator will rotate through them, biased toward whichever phase has the fewest entries in the ledger. Early on this means lots of phase 1. Once findings stack up the rotation naturally tilts toward phase 2. Once solutions exist the rotation naturally tilts toward phase 3. The fleet self-balances without you having to schedule anything.

## How the supervisor catches problems

Autonomous agent loops have two famous failure modes. Either they slide into a polish loop where they keep refining the same files instead of producing new ones, or they drift off scope and start producing material that has nothing to do with the goal. The supervisor is the thing that catches both.

After every fire it does these checks.

- Did any new files get written this fire? If three fires in a row produce zero new files the supervisor writes `orchestrator/STUCK.md` and the next fire halts.
- Is the same role being picked over and over? More than three fires in a row with the same role triggers a warning.
- Is the polish ratio creeping up? When more than 60 percent of fires across a sliding window classify as polish rather than breadth, the supervisor halts.

When the supervisor writes `STUCK.md` the operator looks at `SUPERVISOR_LOG.jsonl` and the per-fire reports under `orchestrator/WORKER_REPORTS/`, decides what changed, and removes `STUCK.md` to resume.

You can read the full rules in `orchestrator/SUPERVISOR.md`.

## Customizing it

Four files cover almost everything.

| File | What you change |
|---|---|
| `orchestrator/NORTH_STAR.json` | The actual goal of your fleet. One sentence in the `mission` field plus a list of current gaps. |
| `orchestrator/WORKER_ROLES.md` | The roles. Add an H2 heading per role with mission, sources, per-run output, quality bar. The manager auto-discovers them. |
| `projects/<name>/PROJECT_TARGETS.md` | The inputs each role consumes. This is where you put your actual research targets, files to refactor, problems to solve, whatever. |
| `.env` | Tick interval, fleet size, model selection, push behavior. |

To run multiple parallel projects, copy `projects/example-project/` to a new name, drop in fresh targets, and set `ACTIVE_PROJECT=<your-name>` in `.env`.

## Troubleshooting

**Manager logs say `canary FAILED`.** Your Claude Max session expired or hit a rate limit. The manager will sleep and retry on its own. If it persists for more than a couple of cycles, check `docker compose logs manager` for the actual error text and confirm your host can run `claude` directly.

**Workers are running but no files appear.** Check `orchestrator/WORKER_REPORTS/` for the per-fire result envelopes. `status: no_files_written` means Claude ran but produced nothing, usually because the role brief is too vague or the targets are already exhausted. `status: fast_fail` means Claude exited in under 60 seconds, almost always a Max-plan throttle, and the worker is sleeping it off.

**Fleet wrote `STUCK.md`.** Read it. Read the supervisor log. Decide if you need new targets, a new role, or just to remove `STUCK.md` and retry.

**Files show up with wrong ownership.** The Dockerfiles use `ARG USER_UID` and `USER_GID` from the host. Pass `UID=$(id -u) GID=$(id -g)` to `docker compose` or set them in `.env`.

## Architecture diagram

See `docs/architecture.md` for the full per-tick flow and the auth model. Short version of the data flow:

```
manager  ── LPUSH job ──>  redis  <── BRPOP ── worker N
manager  <── BRPOP result ── redis  <── LPUSH ── worker N
                                            │
                                            ↓
                                  writes files into ./projects/<name>/
                                            │
                                            ↓
                            manager commits + optionally pushes
```

## Credit

Architecture lineage is the BitBooth autopilot pattern (Drock91), split into a multi-container fleet for the multi-agent case. License is MIT, do whatever you want with it.
