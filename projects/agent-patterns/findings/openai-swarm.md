# OpenAI Swarm — Lightweight Multi-Agent Orchestration

**Source:** https://github.com/openai/swarm  
**Date Fetched:** 2026-05-22  
**Quality Tier:** 4 — Authoritative framework documentation with production evolution guidance; educational framework now superseded by Agents SDK

---

## Summary

OpenAI Swarm (released October 2024, now superseded by the Agents SDK in March 2025) demonstrates a minimalist architecture for multi-agent coordination centered on two primitives: agents (instructions + tools) and handoffs (control flow via function returns). Built directly on the Chat Completions API with no additional dependencies, Swarm prioritizes developer control and testability over managed state. The framework is deliberately kept lightweight to expose orchestration patterns clearly; OpenAI explicitly recommends migrating to the production Agents SDK for all non-educational use. Understanding Swarm's design decisions—particularly its client-side execution model, function-based handoffs, and streaming patterns—illuminates the trade-offs between simplicity and state persistence across the broader multi-agent framework landscape.

---

## Key Findings

1. **Two Primitives: Agents and Handoffs Enable Complex Orchestration**
   - An **Agent** encapsulates three elements: instructions (static or dynamic), tools (functions), and optional tool-choice constraints. Unlike the assistants model, agents are entirely stateless and client-managed. Instructions can receive context variables, enabling dynamic behavior without persistent memory.
   - A **Handoff** occurs when a tool function returns an Agent object, triggering control transfer in the execution loop. This design inverts orchestration from explicit state machines into function-driven routing. The simplicity is deceptive: complex workflows emerge from chaining handoffs, yet the mechanism is trivial to understand and test.
   - Comparison to Anthropic's patterns: agents map to the "orchestrator-worker" pattern (one agent delegating to specialists via tool returns), while handoffs implement the "routing" pattern dynamically. Swarm makes handoffs a first-class abstraction; other frameworks require building them via custom orchestration logic.

2. **Client-Side Execution and Statelessness Trade Managed State for Control**
   - The core `client.run()` loop implements straightforward semantics: (1) request completion from current agent; (2) execute tool calls; (3) check for handoffs; (4) update context; (5) repeat until no new function calls. All state management (context variables, conversation history, agent state) lives on the client. Anthropic's Assistants API or hosted orchestration layers manage state on the server; Swarm explicitly delegates this to the developer.
   - This design trades convenience for control. Developers manage their own persistence, replay, and recovery logic—but they own every decision. There are no hidden framework behaviors, no eventual consistency surprises, and no managed resource quotas. For teams exploring orchestration patterns, this transparency is pedagogically valuable; for production systems requiring reliable state management, it's a liability.
   - Implication for agent-patterns: this represents the "control-oriented" end of a spectrum; frameworks like LangGraph add persistence and checkpointing, trading developer visibility for operational safety.

3. **Function Returns Drive All Transitions (Including Handoffs and Result Objects)**
   - Swarm's execution loop treats function returns polymorphically. A function can return: a primitive value (continues current agent), an Agent object (triggers handoff), a Result object (combines values + agent + context updates), or nested combinations.
   - The Result object signature is `Result(value, agent, context)` with all three optional. This enables "single function returns a value AND updates the agent AND updates context"—expressing complex state transitions in one return. Compare to systems requiring separate API calls for each type of update.
   - Function definitions are automatically converted to JSON Schema via docstrings + type hints. Descriptions become critical: the model uses them to decide when to call each function. Swarm emphasizes that "excellent tool design makes agents reliable with minimal orchestration logic"—identical to [[building-effective-agents.md|Anthropic's principle]] and [[claude-tool-use.md|the tool-use contract]].

4. **Context Variables Enable Lightweight State Sharing Without Centralized Memory**
   - Functions can accept and return context variables (arbitrary Python dicts), which persist through the execution chain. This is Swarm's answer to "how do agents share state?" without a managed conversation store. Context flows as a parameter to every function; functions can read, modify, and return updated context.
   - Contrast to LangGraph, which manages state persistence and checkpointing in the framework. Swarm delegates this: developers explicitly thread context through function signatures. The trade-off is clarity (context mutations are visible in function definitions) vs. ergonomics (more plumbing code).
   - For simple 2–5 agent workflows, context variables suffice. For complex long-running systems with branching paths, teams typically migrate to hosted orchestration (Agents SDK, LangGraph) to avoid reinventing state persistence.

5. **Streaming Support Extends Chat Completions with Agent-Specific Events**
   - Swarm's streaming mode emits delimiters marking agent switches and aggregates response objects, extending the Chat Completions streaming protocol. This enables real-time visibility into multi-agent handoffs without buffering entire conversation histories.
   - Server-executed tools (like web search) are handled through standard Chat Completions tool iteration; client-side tools require explicit loop management. The streaming design is consistent with [[claude-tool-use.md|Claude's tool-use contract]]: the framework doesn't execute; it requests; the application drives the loop.
   - Practical implication: developers can build real-time dashboards showing agent transitions and tool execution progress. This transparency aligns with [[building-effective-agents.md|Anthropic's principle]] that "agents should make reasoning visible."

6. **Error Recovery is Implicit; Malformed Tool Calls Append Error Messages**
   - If a tool call fails or is malformed, Swarm appends an error message to the conversation history, allowing the current agent to recover or escalate. There is no exception handling framework; errors become part of the conversation.
   - This design is minimalist but exposes developers to error-handling complexity. Production systems using Swarm typically wrap the execution loop to catch exceptions, log them, and decide whether to retry, escalate to a human, or abort.
   - Comparison: the Agents SDK (Swarm's successor) adds observability, built-in retry logic, and structured error handling. Educational value of Swarm is that it exposes what the orchestration framework must hide.

7. **Educational Framework Positioning; Production Successor is the Agents SDK**
   - OpenAI explicitly states: "Migrate to the Agents SDK for all production use cases." The Agents SDK (released March 2025) adopts Swarm's conceptual model—agents with instructions + tools, handoffs via function returns—but adds production features: managed state, observability, error handling, and hosted execution.
   - Swarm is designed for teams learning multi-agent patterns (2–5 agent workflows, rapid prototyping). It has no persistence layer, no observability, and no built-in error recovery. Scaling beyond a small demo requires architectural decisions Swarm punts to the developer.
   - Relevance to agent-patterns research: Swarm is valuable as a reference for understanding what a minimal agent abstraction looks like and why frameworks add complexity. The patterns it exposes (handoffs, context threading, streaming) are foundational; the lack of production features (state management, observability) illustrates where real systems diverge.

---

## Cross-References

**Related findings files** (within projects/agent-patterns/):
- [[building-effective-agents.md]]: Swarm implements the "orchestrator-worker" pattern via agents and handoffs; Anthropic's five core patterns are the theoretical foundation for what Swarm operationalizes.
- [[claude-tool-use.md]]: Tool design and the agentic loop are identical across Swarm and Claude; tool quality matters more than orchestration framework complexity.
- [[multi-agent-systems-in-claude.md]]: Swarm represents the lightweight, client-side end of multi-agent architecture; comparison with Claude's orchestrator/subagent patterns shows the trade-offs.
- [[langgraph-concepts.md]]: LangGraph adds persistence and checkpointing to multi-agent workflows; Swarm's lack of these features highlights the value-add of stateful frameworks.

**Related external references:**
- [OpenAI Agents SDK](https://platform.openai.com/docs/guides/agents) — Swarm's production successor; identical conceptual model with added state management and observability.
- [OpenAI Swarm on GitHub](https://github.com/openai/swarm) — Source code, examples, and API reference.

---

## Framework Comparison: Swarm vs. Other Orchestration Layers

| Dimension | Swarm | Agents SDK | LangGraph |
|-----------|-------|-----------|-----------|
| **State management** | Client-side (developer-owned) | Managed (OpenAI-hosted) | Managed (developer-owned via checkpointing) |
| **Persistence** | None (in-memory) | Built-in (threads) | Built-in (checkpoints) |
| **Streaming** | Custom events | Native | Native |
| **Model flexibility** | Chat Completions | Chat Completions | Any LLM |
| **Execution** | Client-side | Hosted | Client-side |
| **Observability** | Manual logging | Built-in | Manual or custom integration |
| **Production-ready** | No (educational) | Yes | Yes (with caveats) |
| **Entry barrier** | Low (2–3 agent demos) | Low (managed state) | Medium (graph model learning) |

---

## Implementation Implications for Agent-Fleet-Skeleton

1. **Swarm's Minimalism Exposes Core Orchestration Challenges**
   - State sharing, handoff routing, and error recovery are not hidden by the framework. Teams building agent-patterns research benefit from understanding what Swarm leaves to the developer and why production systems add layers (LangGraph, Agents SDK) around it.

2. **Function-as-Handoff Pattern is Transferable**
   - Swarm's design of returning Agent objects to trigger handoffs is elegant and worth adopting in fleet architecture if the fleet needs to delegate research across workers or reassign tasks to specialized agents.

3. **Context Threading vs. Centralized State is an Architectural Choice**
   - Swarm demonstrates explicit context threading; this clarifies dependencies but adds boilerplate. The fleet's use of an ANTI_LOOP_LEDGER and explicit WORKER_ROLES is a higher-level analog: explicit role assignment and output traceability instead of implicit framework-managed routing.

4. **Error Recovery Should Be Explicit**
   - Swarm appends errors to conversation history. The fleet should adopt similar patterns: document failures in the ledger, make recovery decisions transparent, and avoid silent failures. Educational value comes from seeing what breaks and why.

5. **Streaming and Real-Time Visibility are Valuable for Multi-Agent Coordination**
   - For human-in-the-loop research orchestration, Swarm's streaming model (showing agent transitions in real-time) could inform how the fleet reports progress to supervisors or observability systems.

---

## Status

✓ **Initial findings extracted.** Sufficient detail to serve as a reference for multi-agent orchestration and lightweight vs. production framework trade-offs. Ready for synthesis once patterns across Tier 2 frameworks (LangGraph, Swarm) are compared.

**Next actions for fleet:**
- Comparative synthesis on "Lightweight vs. Stateful Multi-Agent Architectures" (connecting Swarm, LangGraph, and Claude's Agents SDK) will clarify when to choose each approach.
- ReAct paper (Tier 3) will provide the theoretical foundation for agent reasoning loops that Swarm operationalizes but doesn't invent.
