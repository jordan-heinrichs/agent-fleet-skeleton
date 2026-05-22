# Multi-Agent Systems in Claude — Managed Agents & Orchestration Patterns

**Source:** https://platform.claude.com/docs/en/managed-agents/overview + https://www.anthropic.com/engineering/multi-agent-research-system  
**Date Fetched:** 2026-05-22  
**Quality Tier:** 5 — Authoritative documentation combining official API reference with production lessons from Anthropic's own research system

---

## Summary

Claude Managed Agents provides production infrastructure for autonomous, long-running agent workloads with stateful sessions, built-in tools, and server-side persistence. The platform implements the orchestrator-worker pattern at scale, where lead agents decompose tasks and spawn subagents to execute work in parallel. Anthropic's internal research system—operating orchestrators (Claude Opus) with subagents (Claude Sonnet)—achieved 90% performance improvement over single-agent Opus on complex queries by leveraging token efficiency, parallel execution, and explicit delegation patterns. Multi-agent systems introduce state management and debugging complexity that require durable execution, resumption capabilities, and high-level observability, but yield dramatic improvements in both speed and capability when properly designed.

---

## Key Findings

1. **Orchestrator-Worker Pattern Dominates Multi-Agent Design**
   - Multi-agent systems decompose complex tasks via a lead agent that analyzes queries, develops strategy, and spawns specialized subagents working in parallel. The lead agent synthesizes results and determines if additional research is needed. In Anthropic's research system, allocation scales by complexity: simple queries run with 1 agent, comparisons use 2-4 subagents, complex research spawns 10+ subagents. This explicit allocation prevents resource waste and ensures effort matches query difficulty. The pattern mirrors the five core workflows from "Building Effective Agents," with orchestrator-worker being the primary mechanism for dynamic task decomposition at scale.

2. **Parallelization Reduces Research Time by Up to 90%**
   - Multiple subagents spawn and execute simultaneously rather than sequentially, with each subagent making 3+ tool calls in parallel. This compressed execution timeline—combining both agent-level and tool-level parallelization—results in up to 90% reduction in research time for complex queries. Token usage is the primary performance driver (80% of variance); model choice (Opus vs. Sonnet) and tool call efficiency explain the remaining 15%. Multi-agent systems use approximately 4× the tokens of single-turn interactions and 15× more than standard chat, making token efficiency through subagent specialization critical for cost control.

3. **Prompt Engineering Determines Delegation Quality and Prevents Duplication**
   - Subagent performance depends on explicit, detailed task descriptions that communicate objectives, output formats, tool guidance, and clear boundaries. Lead agents must teach delegation patterns: simulate agent behavior before deployment to understand decision patterns, embed scaling rules matching effort to complexity, and provide tool guidance that prevents duplication across subagents. Prompt engineering is the most controllable lever in multi-agent systems; architectural complexity (more agents, more tools) does not compensate for poor delegation instructions. Self-improvement loops—where Claude diagnoses prompt weaknesses and suggests refinements—are already in use at Anthropic to iterate agent prompts without manual rewrites.

4. **Claude Managed Agents Handles Infrastructure; Developers Control Agent Logic**
   - Claude Managed Agents is a pre-built harness that eliminates the need to implement custom agent loops, sandbox execution, or tool infrastructure. The platform provides: (a) stateful sessions that resume cleanly after pauses with persistent conversation history and container state; (b) built-in tools (bash, file operations, web search/fetch, MCP server integration); (c) server-side event streaming with full event history persistence; (d) cloud containers or self-hosted sandboxes for compliance requirements. This removes boilerplate but requires the developer to define agent configuration (model, system prompt, tools, MCP servers) and to manage the semantics of task decomposition, delegation criteria, and result synthesis.

5. **State Management and Error Recovery Are Bottlenecks in Production**
   - Multi-agent systems introduce non-deterministic behavior: agent decisions vary between runs, state accumulates across many tool calls, and minor system failures become catastrophic without resumption capabilities. Durable execution and error recovery are non-negotiable; current synchronous implementations where lead agents wait for subagent completion limit parallelism. Production systems require: (a) rainbow deployments to gradually shift traffic between versions; (b) high-level observability monitoring decision patterns without accessing sensitive conversation contents; (c) strong logging of orchestration decisions (task decomposition, subagent selection, synthesis logic). Asynchronous execution would improve parallelism but adds coordination complexity; the trade-off is still open in production systems.

6. **Performance Metrics: Opus + Sonnet Subagents Outperforms Single Opus**
   - Anthropic's research system measured multi-agent performance against single-agent Opus 4 baseline on internal research evaluations. Result: Opus 4 lead + Sonnet 4 subagents achieved **90.2% higher performance** on complex research tasks. This improvement persists across diverse use cases: software system development (10% of use cases), professional content optimization (8%), business strategy development (8%), academic research support (7%), information verification (5%). Users report discovering new business opportunities, navigating complex decisions, reducing research time by multiple days. The performance gain is robust: evaluation with LLM-as-judge (using rubric criteria: factual accuracy, citation accuracy, completeness, source quality, tool efficiency) confirms improvements across categories.

7. **Stateful Sessions Enable Long-Running Tasks But Limit Zero Data Retention Eligibility**
   - Sessions persist conversation history, container state, and outputs server-side, enabling resumption and steering mid-execution (send additional user messages to guide the agent or interrupt to change direction). This statefulness is essential for long-running tasks (minutes or hours with multiple tool calls) but comes with data retention trade-offs: Claude Managed Agents is not currently eligible for Zero Data Retention (ZDR) or HIPAA BAA coverage. Developers retain control: sessions and uploaded files can be deleted via API at any time. The data residency requirement (sessions in managed cloud containers or self-hosted sandboxes) is a compliance decision: cloud containers (Anthropic-managed) vs. self-hosted (your infrastructure) matching data sovereignty needs.

---

## Cross-References

**Related findings files** (within projects/agent-patterns/):
- [[building-effective-agents.md]]: Orchestrator-worker pattern is one of the five core workflows; multi-agent systems instantiate this pattern at production scale with Managed Agents infrastructure.
- [[claude-tool-use.md]]: Tool use is the primitive mechanism enabling subagent delegation; multi-agent systems rely on tool definitions and agentic loops, now abstracted by Managed Agents infrastructure.

**Related orchestrator documents:**
- [SUPERVISOR.md](../../orchestrator/SUPERVISOR.md): Supervisor implements similar orchestration principles (task decomposition, parallel execution, result synthesis) for detecting fleet health; understanding agent delegation helps interpret how Supervisor allocates work to worker roles.

---

## Architectural Implications for Multi-Agent Systems

1. **Delegation Pattern Over Agent Count**
   - More agents don't automatically improve results. Explicit task decomposition and clear delegation instructions drive performance. The lead agent must understand when to spawn subagents (by query complexity) and what boundaries to set (to prevent duplication). This is a prompt engineering problem, not an infrastructure problem.

2. **Token Efficiency is the Primary Optimization Target**
   - Multi-agent systems use 4-15× more tokens than chat or single-turn interactions. Optimizing token usage (through model selection, parallelism, subagent specialization) delivers the largest performance gains (80% of variance). Tool definitions and delegation prompts should be precise without being verbose.

3. **Observability Must Capture Orchestration Decisions Without Leaking Conversation Content**
   - Non-determinism in multi-agent systems requires production tracing of what agents decide (task decomposition choices, subagent selection, synthesis reasoning). High-level decision logging should capture these without surfacing sensitive conversation history.

4. **Error Recovery and Resumption Are Non-Negotiable for Production**
   - Durable execution, session persistence, and resumption capabilities are mandatory when multiple agents coordinate. Rainbow deployments and gradual traffic shifts prevent breaking changes. Synchronous blocking (lead agent waits for subagents) is the current implementation; asynchronous improvements are an open research direction.

---

## Status

✓ **Complete reference material on multi-agent architectures and Managed Agents infrastructure.** Spans both official API documentation and production lessons from Anthropic's internal research system, providing both "what to build" (orchestrator-worker patterns) and "what can go wrong" (state management, debugging, error recovery).

**Next synthesis target for fleet:**
- Three Tier 1 findings (building-effective-agents, claude-tool-use, multi-agent-systems-in-claude) now complete. **Synthesis opportunity:** Connect these three to produce "Tier 1 Foundation" synthesizing the architecture stack: tool use as primitive → five core patterns → multi-agent orchestration as production instantiation.
- Tier 2 (LangGraph concepts, OpenAI Swarm) will provide comparative analysis of how different frameworks instantiate these patterns.
- Tier 3 (ReAct paper) will provide theoretical foundation explaining why the orchestrator-worker loop succeeds.
