# Building Effective Agents — Anthropic Research

**Source:** https://www.anthropic.com/research/building-effective-agents  
**Date Fetched:** 2026-05-22  
**Quality Tier:** 5 — Authoritative source material with direct applicability to agent fleet architecture

---

## Summary

Anthropic's "Building Effective Agents" provides a foundational framework for designing agentic systems, distinguishing between workflows (predefined, code-orchestrated systems) and agents (dynamic, LLM-directed systems). The research identifies five core patterns for building workflows and establishes design principles that prioritize simplicity, transparency, and thoughtful tool-design over framework complexity. This document serves as a critical reference for understanding when and how to introduce agent autonomy versus structured process orchestration.

---

## Key Findings

1. **Workflows vs. Agents is a False Binary**
   - Systems exist on a spectrum: pure workflows use predefined code paths; pure agents have the LLM dynamically controlling flow. Most production systems are hybrid, mixing structured sequences with dynamic branching. The distinction matters for architecture decisions but shouldn't force a rigid either/or choice.

2. **Simplicity is the Strongest Design Constraint**
   - Anthropic's primary recommendation: start with a single LLM call and optimize it before adding complexity. Only introduce multi-step systems when simpler solutions demonstrably fail performance or capability requirements. Many teams prematurely adopt agent frameworks when prompt engineering or tool selection would solve the problem more reliably.

3. **Five Core Workflow Patterns Cover Most Use Cases**
   - **Prompt Chaining:** Decompose tasks into sequential steps with programmatic verification between stages. Each step focuses on one subtask; verification gates prevent error propagation. Useful for structured tasks with clear intermediate outputs.
   - **Routing:** Classify inputs at the entry point and direct them to specialized downstream processes. Router complexity scales linearly with classification accuracy; reduces per-specialist model load.
   - **Parallelization:** Run subtasks simultaneously (dividing a task into sections) or run identical tasks multiple times (voting/aggregation for consistency). Parallelization trades latency for cost; voting trades cost for reliability.
   - **Orchestrator-Workers:** A central LLM dynamically breaks down tasks and delegates to specialist worker LLMs. Workers can be task-specific or capability-specific. Introduces dynamic branching while maintaining clarity of purpose.
   - **Evaluator-Optimizer:** One LLM generates responses; another evaluates and provides feedback for iterative refinement. Decoupling generation and evaluation enables stronger feedback signals and clearer failure analysis.

4. **Tool Design Matters More Than Agent Framework Complexity**
   - Agents are fundamentally "LLMs using tools based on environmental feedback in a loop." Sophistication comes from clear tool documentation, appropriate tool granularity, and correct affordances—not from adding framework complexity. Poor tool design breaks agents; excellent tool design makes agents reliable with minimal orchestration logic.

5. **Three Core Design Principles Enable Reliability**
   - **Maintain Simplicity:** Every component should have a single, clear purpose. Multi-purpose components become harder to debug and optimize when failures occur.
   - **Prioritize Transparency:** Explicitly log and show the agent's planning steps, tool calls, and reasoning. Black-box agent behavior is impossible to debug; transparent systems are.
   - **Carefully Craft the Agent-Computer Interface (ACI):** The interface between the LLM and the tools/environment should reflect the actual decision boundaries the agent faces. Poor ACI design forces the LLM to encode context or workarounds.

6. **Iteration and Measurement Drive Real Improvements**
   - Rather than adopting a framework because it's "more agentic," measure specific capabilities: tool accuracy, latency, cost, and error rates. Iterate on the bottleneck. Many real-world systems improve faster by tuning a single well-designed LLM than by adding another agent layer.

---

## Cross-References

**Related findings files** (within projects/agent-patterns/):
- [[claude-tool-use.md]]: Tool use is the primitive underlying every agent loop; this document details the mechanism and constraints.
- [[multi-agent-systems-in-claude.md]]: Multi-agent patterns extend these five workflows; orchestrator-worker and evaluator-optimizer form the basis for multi-agent decomposition.

**Related orchestrator documents:**
- [SUPERVISOR.md](../../orchestrator/SUPERVISOR.md): Supervisor uses similar design principles (simplicity, transparency, iterative refinement) to detect fleet health and prevent polish loops.

---

## Implementation Implications for Agent-Fleet-Skeleton

1. **Fleet orchestration should prioritize prompt chaining and routing** as the initial patterns, with orchestrator-worker only when dynamic delegation adds value over static task assignment.

2. **Tool design (defining agent capabilities) precedes orchestration logic.** Invest in clear, scoped tool interfaces before adding multi-agent complexity.

3. **Transparency requirements align with the ledger-driven anti-loop system:** Explicit logging of each fire's output (findings → synthesis) mirrors the recommendation that agents should make their reasoning visible.

4. **The five patterns provide a vocabulary** for evaluating whether a fire's output represents breadth, depth, connect, or polish. Fires that introduce new patterns or cross-cut existing ones are high-signal; fires that repeat the same output structure are low-signal.

---

## Status

✓ **Initial findings extracted.** Sufficient detail to serve as a reference for tool-use documentation and multi-agent patterns. Ready for synthesis once additional Tier 1 findings (tool-use, multi-agent-systems) are complete.

**Next actions for fleet:**
- Comparative findings on LangGraph and OpenAI Swarm (Tier 2 patterns) will show how different frameworks instantiate these five core patterns.
- ReAct paper (Tier 3) will provide the theoretical foundation for the feedback loop.
