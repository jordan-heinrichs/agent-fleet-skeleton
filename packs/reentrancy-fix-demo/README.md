# Pack: reentrancy-fix-demo

A small, complete **three-phase** pack: take one well-known smart-contract bug
from explanation, to fix design, to working code. It exists to show the fleet
running end to end in a few minutes, on either provider, and to serve as the
canonical example of the research → design → implement pattern.

## The bug it solves

The classic reentrancy hole: a vault whose `withdraw()` sends ETH **before**
zeroing the caller's balance, so a malicious recipient can re-enter `withdraw()`
and drain the contract.

```solidity
function withdraw() external {
    uint256 amount = balances[msg.sender];
    (bool ok, ) = msg.sender.call{value: amount}("");   // external call FIRST
    require(ok);
    balances[msg.sender] = 0;                            // state update AFTER
}
```

This is the same bug class behind The DAO hack (2016). See `TARGETS.md`.

## The three roles (one per phase)

| Phase | Role | Reads | Writes |
|---|---|---|---|
| 1. gather | `researcher` | `TARGETS.md` | `output/research/reentrancy-explained.md` |
| 2. design | `solution-architect` | phase-1 research | `output/solutions/reentrancy-fix-design.md` |
| 3. implement | `implementer` | phase-2 design | `output/implementations/SafeVault.md` |

Each role's brief and quality bar live in `ROLES.md`. The orchestrator
auto-discovers all three and rotates through them; with `FLEET_SIZE=3` one fire
produces all three documents.

## Run it

Set these in the repo-root `.env`, then start the fleet:

```bash
ACTIVE_PACK=reentrancy-fix-demo
AGENT_PROVIDER=claude       # or: ollama
AGENT_MODEL=sonnet          # or: qwen2.5-coder:14b
CANARY_MODEL=haiku          # or, for ollama: qwen2.5-coder:14b
FLEET_SIZE=3
```

```bash
docker compose up -d --build
docker compose logs -f manager
```

Output appears under `packs/reentrancy-fix-demo/output/`. (That directory is
git-ignored; the committed `sample-output/` below is a captured run.)

## Verified output

One fire, both providers, same pack:

| Phase | File | Claude (`sonnet`) | Ollama (`qwen2.5-coder:14b`, local, $0) |
|---|---|---|---|
| 1. research | `research/reentrancy-explained.md` | 189 lines | 65 lines |
| 2. design | `solutions/reentrancy-fix-design.md` | 192 lines | 115 lines |
| 3. implement | `implementations/SafeVault.md` | 93 lines | 42 lines |

Both runs were correct and on target: a real account of the re-entry sequence,
a design covering all three standard defenses (Checks-Effects-Interactions, a
reentrancy guard, pull-over-push), and Solidity that applies CEI plus
OpenZeppelin's `nonReentrant`. Claude's documents are deeper and more
thoroughly sourced; the local model's are shorter but technically sound, at
zero cost and no rate limit.

The actual generated files from both runs are checked in for inspection:

- `sample-output/claude/` — the Claude run
- `sample-output/ollama/` — the local Ollama run

## Why this pack is a good template

It is the smallest thing that exercises every moving part: role discovery,
the three-phase rotation, the anti-loop ledger, per-provider prompting, and the
commit loop. Copy it, swap the bug for your own domain's targets, rewrite the
three role briefs, and you have a new pipeline.
