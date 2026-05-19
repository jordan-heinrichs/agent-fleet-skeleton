# PROJECT_TARGETS — example-project

This is a placeholder. Replace the contents with your actual targets.

The `researcher` role will pick targets from this list. The `synthesizer`
role will then connect findings across them.

---

## Tier 1 — Highest priority

- [Yellow Network whitepaper](https://docs.yellow.com) — the core architecture
- [State channels primer (Lightning Network)](https://github.com/lightningnetwork/lightning-rfc) — adjacent prior art
- [Perun state channels paper](https://eprint.iacr.org/2019/219.pdf) — academic foundation

## Tier 2 — Adjacent topics

- ERC-7683 cross-chain intents specification
- HTLC (hashed timelock contracts) on Bitcoin and Ethereum
- Decentralized clearinghouse architectures across CEX/DEX boundaries

## Tier 3 — Background

- Ripple's Interledger Protocol (ILP) history and current state
- Cosmos IBC vs LayerZero vs Axelar architectural comparison
- Off-chain settlement patterns in traditional finance (Continuous Linked Settlement, etc.)

---

## How this file works

Workers read this file as part of their prompt. They will pick a target NOT
already in `orchestrator/ANTI_LOOP_LEDGER.md`. New targets you want covered
go at the top of the appropriate tier.

You can mix and match different kinds of targets in the same file (whitepapers,
repos, RFCs, blog series, etc.). The role briefs determine how each kind gets
processed.
