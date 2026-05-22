# Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│                          docker-compose.yml                           │
│                                                                       │
│   ┌────────────┐         ┌────────────┐         ┌────────────┐        │
│   │  manager   │ ──LPUSH→│   redis    │←──BRPOP─│  worker N  │        │
│   │            │         │            │         │            │        │
│   │ 1 replica  │←─BRPOP──│ jobs +     │ ──jobs─→│ N replicas │        │
│   └─────┬──────┘ results │ results    │         │ (FLEET_SIZE)│       │
│         │                └────────────┘         └─────┬──────┘        │
│         │                                             │               │
│         ↓                                             ↓               │
│    canary check                              `claude --print` per job │
│    (Haiku ping)                                      ↓                │
│         │                                             │               │
│         └──────────── git commit + optional push ────┘               │
│                                                                       │
└──────────────────────────────────────────────────────────────────────┘
                              │
                              │ bind mount
                              ↓
                ┌─────────────────────────────┐
                │ ./ (this repo on the host)  │
                │                             │
                │ orchestrator/               │
                │   NORTH_STAR.{md,json}      │
                │   WORKER_ROLES.md           │
                │   ANTI_LOOP_LEDGER.md       │
                │   SUPERVISOR.md             │
                │   SUPERVISOR_LOG.jsonl      │
                │   WORKER_REPORTS/           │
                │                             │
                │ projects/<active>/          │
                │   PROJECT_TARGETS.md        │
                │   findings/    (worker out) │
                │   synthesis/   (worker out) │
                └─────────────────────────────┘
```

## Per-tick flow

1. **Manager** wakes from sleep, runs a canary check against `claude` with
   the Haiku model. If the canary fails (network down, rate-limited, auth
   broken), the manager sleeps `PAUSE_BASE_MINUTES` (default 30) and retries.
2. **Manager** discovers available roles by grepping `## <name>` headings in
   `orchestrator/WORKER_ROLES.md`. It counts `← <role>` entries in
   `ANTI_LOOP_LEDGER.md` per role, sorts ascending, and picks the lowest
   `FLEET_SIZE` count roles.
3. **Manager** drains the result queue (atomic Redis `DEL`) then LPUSHes one
   job per picked role. Each job is a small JSON envelope with role, fire id,
   project name, and timeout.
4. **Workers** are blocked on `BRPOP fleet:jobs`. Each grabs one job, builds
   a prompt that embeds the role brief + project targets + recent ledger
   tail, and runs `claude --print` with the model from `AGENT_MODEL`.
5. **Workers** write outputs straight to the bind-mounted workspace. After
   `claude` exits, the worker counts new files via `find` diff, packages a
   result envelope, and LPUSHes it to `fleet:results`.
6. **Manager** has been BRPOP-ing `fleet:results`. It collects N results
   with a deadline equal to worker timeout + 5-min grace. If the deadline
   fires with fewer than N results, it proceeds anyway.
7. **Manager** runs the supervisor pass. If three consecutive fires have
   produced zero files, it writes `STUCK.md` and halts the loop.
8. **Manager** `git add -A`, commits with a fire-id-tagged message, and
   optionally pushes if `AGENT_AUTO_PUSH=true`.
9. **Manager** sleeps `TICK_INTERVAL_MINUTES`.

## Auth model

The manager and the workers all mount the host's `~/.claude` directory plus
`~/.claude.json` as read-only side-path. On boot they copy a stable snapshot
of `~/.claude.json` so the host's interactive Claude Code session can keep
writing to its own copy without corrupting the containers mid-call.

Setting `ANTHROPIC_API_KEY` anywhere in the stack will route the CLI through
API-key billing and bypass the Max subscription. The `.env.example` leaves it
explicitly commented out for that reason.

## Fast-fail backoff

If `claude` exits non-zero in under 60 seconds, the worker treats it as a
Max-plan throttle even when the error text doesn't match the hardcoded
exhaustion regex. The worker emits a `fast_fail` result and sleeps
`PAUSE_BASE_MINUTES`. This prevents the fleet from burning through retries
during a closed rate-limit window. The same logic on the manager-side canary
ensures the manager never enqueues a fire into a closed window.

## Lineage

The architecture is the BitBooth autopilot pattern (Drock91) split into a
multi-container fleet. The original was a single agent ticking on one repo;
this version is N parallel agents coordinated by a redis-backed orchestrator,
with the supervisor and anti-loop ledger preserved unchanged in spirit.
