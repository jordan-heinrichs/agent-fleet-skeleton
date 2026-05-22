# Contributing

This is a skeleton. The best contributions either make the core loop more
reliable or make it easier to point at a new kind of work. Both are welcome.

## Local setup

```bash
git clone https://github.com/Drock91/agent-fleet-skeleton
cd agent-fleet-skeleton
cp .env.example .env
docker compose up -d --build
docker compose logs -f manager
```

You need Docker and a host `~/.claude` session (Claude Max). No API key.

## The two most common contributions

### Adding a worker role

Append an H2 section to `orchestrator/WORKER_ROLES.md` following the shape of
the existing roles. Required parts: mission, sources, per-run output spec,
quality bar, anti-loop note. The manager auto-discovers roles by H2 heading,
so there is no registration step. Rebuild and the new role enters rotation on
the next fire.

### Adding a project

Create `projects/<name>/PROJECT_TARGETS.md`, set `ACTIVE_PROJECT=<name>` in
`.env`, rebuild. The example project shows the expected layout.

## Changing the entrypoints

The manager and worker loops are plain bash. A few conventions to keep them
debuggable.

- Log to stderr, not stdout. Functions used inside `$(...)` or `< <(...)`
  must not pollute their captured output. (`log()` already routes to stderr.)
- `grep -c` prints `0` and exits 1 on no match. Never write
  `count=$(grep -c ... || echo 0)` — it produces a two-line `0\n0`. Pipe
  through `head -n1` and guard for empty instead.
- The manager owns every write under `orchestrator/`. Workers are read-only
  there by design. If a worker needs to record something, put it in the
  result envelope and let the manager write it.
- Run `bash -n docker/manager/entrypoint.sh` and
  `bash -n docker/worker/entrypoint.sh` before committing entrypoint changes.

## Security contributions

See `SECURITY.md` for the threat model and the containment measures in place.
Findings that tighten the blast radius of `--dangerously-skip-permissions`
are the highest-value contributions to this repo. Label the PR with the
finding (for example `C-03`) and explain what an attacker could do before the
fix and what they can do after.

## Commit style

Real commit messages. Say what changed and why. If a change builds on someone
else's work, credit them in the body and reference the PR or commit. The
project history should read like a record of decisions, not a changelog of
diffs.

## Pull requests

Small and focused beats large and sweeping. One concern per PR. If a PR fixes
a bug, describe how you verified the fix even if there is no test suite yet
(a mock run, a `bash -n`, a manual fire, whatever you actually did).
