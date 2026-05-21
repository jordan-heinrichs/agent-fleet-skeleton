# PROJECT_TARGETS — agent-patterns

Research goal: document established patterns for building autonomous AI agent
systems. The researcher role collects structured findings from public sources.
The synthesizer role connects patterns across findings once three or more exist.

---

## Tier 1 — Core reading (start here)

- [Building effective agents](https://www.anthropic.com/research/building-effective-agents) — Anthropic's breakdown of agent architectures: workflows vs. agents, augmented LLMs, five core patterns
- [Claude tool use](https://docs.anthropic.com/en/docs/tool-use) — how Claude calls external tools; the primitive every agent system builds on
- [Multi-agent systems in Claude](https://docs.anthropic.com/en/docs/build-with-claude/agents) — orchestrator/subagent patterns, parallelisation, when to use multiple agents

## Tier 2 — Framework comparisons

- [LangGraph concepts](https://langchain-ai.github.io/langgraph/concepts/) — graph-based orchestration, state persistence, human-in-the-loop checkpointing
- [OpenAI Swarm](https://github.com/openai/swarm) — minimalist multi-agent handoff and routines pattern; deliberately kept lightweight

## Tier 3 — Foundational patterns

- [ReAct: Synergizing Reasoning and Acting](https://arxiv.org/abs/2210.03629) — the reasoning-then-acting loop that most tool-using agents implement

---

## How this file works

Workers pick one target per fire from the list above, NOT already in
`orchestrator/ANTI_LOOP_LEDGER.md`. Write findings to
`projects/agent-patterns/findings/<slug>.md`.

Tiers are a priority hint only — the anti-loop ledger and role rotation
determine actual order.