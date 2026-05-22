# Claude Tool Use — API Reference & Implementation Guide

**Source:** https://platform.claude.com/docs/en/agents-and-tools/tool-use  
**Date Fetched:** 2026-05-22  
**Quality Tier:** 5 — Authoritative API reference with complete implementation patterns and best practices

---

## Summary

Claude's tool use system is the primitive mechanism enabling all agent architectures. The system implements a contract where developers define operations (schemas + descriptions), Claude decides when and how to call them, and the application executes the operation and returns results. Tools are categorized by execution location—client-executed tools (user-defined and Anthropic-schema) require the application to drive an agentic loop, while server-executed tools (web search, code execution, web fetch) run on Anthropic's infrastructure. Understanding where tools run and how to design effective tool interfaces is more important than orchestration framework complexity; poor tool design breaks agents, while excellent tool design makes simple agents reliable.

---

## Key Findings

1. **The Tool-Use Contract Inverts Control Flow**
   - Traditional APIs: application calls model with input, receives output. Tool use inverts this: application provides *what it can do*, model decides *when and how* to call those capabilities. The model emits a structured request (`tool_use` block), the application executes, and returns the result. This contract makes Claude behave less like a text generator and more like a callable function with an LLM choosing which function to invoke based on context. The critical implication: the model never executes anything—it only decides and requests; execution is always the application's responsibility.

2. **Tool Execution Location Determines Architecture**
   - **Client-executed tools** (user-defined + Anthropic-schema): Application receives `tool_use` blocks, executes the operation synchronously, and returns results in `tool_result` blocks on the next request. This requires the application to drive a `while stop_reason == "tool_use"` loop—at minimum, three round trips to the API: request + tools → response with `tool_use` → send results → model continues.
   - **Server-executed tools** (web_search, web_fetch, code_execution, tool_search): Anthropic's infrastructure runs the loop internally. A single request may trigger multiple searches or code runs before a response comes back. Server tools have an iteration cap; if the model hits it before finishing, it returns `stop_reason: "pause_turn"` instead of `"end_turn"`, signaling incomplete work that requires continuation.
   - **Mixed strategies**: Production systems typically mix both. Server tools handle integration with external data (web search, code execution). Client tools handle business logic (database queries, internal APIs). The distinction matters for latency, cost, and ownership of the execution loop.

3. **Tool Design Quality Matters More Than Framework Complexity**
   - The most reliable agents don't use the most sophisticated frameworks; they use tools with exceptional design. Tool design has four critical dimensions:
     - **Descriptions**: The single most important factor in tool reliability. Descriptions should explain what the tool does, when to use it (and when not to), what each parameter means, caveats, and limitations. Aim for 3-4 sentences per tool, more for complex tools. Poor descriptions force the model to guess; excellent descriptions make the model reliable.
     - **Schema consolidation**: Avoid one tool per action (`create_pr`, `review_pr`, `merge_pr`). Instead, consolidate into fewer tools with action parameters. Fewer tools reduce selection ambiguity and let the model navigate the surface more easily.
     - **Naming and namespacing**: Use meaningful names with service prefixes (e.g., `github_list_prs`, `slack_send_message`). This prevents ambiguity as tool libraries grow and is especially important when using tool search.
     - **Response design**: Return only signal. Use semantic identifiers (slugs, UUIDs) instead of opaque internal IDs. Include only fields Claude needs to reason about the next step. Bloated responses waste context and confuse the model.

4. **The Agentic Loop is Simple But Critical**
   - Client tools require explicit loop management: (1) Send request with `tools` and message; (2) Claude responds with `stop_reason: "tool_use"` and `tool_use` blocks; (3) Execute each tool; (4) Format outputs as `tool_result` blocks; (5) Send new request with original messages, assistant response, and user message with `tool_result` blocks; (6) Repeat while `stop_reason == "tool_use"`. The loop exits on `"end_turn"`, `"max_tokens"`, `"stop_sequence"`, or `"refusal"`. Every tool call is at least one additional round trip; latency overhead can exceed the tool's actual work for lightweight operations. This loop is where errors accumulate: incorrect `tool_result` formatting, missing `tool_use_id` matching, or incorrect content ordering causes 400 errors and breaks the loop.

5. **Tool Use vs. Direct Answering Has Clear Boundaries**
   - Use tool calls when: actions have side effects (send email, write file, update database); data is external or fresh (current prices, weather, database contents); structured outputs with guaranteed shape are required; integration with existing systems is needed. Use prose when: the model can answer from training alone (summarization, translation, general knowledge); the interaction is one-shot with no side effects; tool latency would dominate the response time. The tell-tale sign: if you're parsing free-form text to extract decisions, that decision should have been a tool call. Structured intent belongs in schemas, not in regex extraction.

6. **Tool Use System Overhead Affects Scaling**
   - When tools are provided, Claude's API automatically includes a special system prompt that enables tool use. Token counts vary by model: Claude Opus and Sonnet add 346 tokens for `tool_choice: auto/none`, or 313 tokens for `tool_choice: any/tool`. Claude Haiku adds the same 346 tokens (as of 4.5). This overhead is per-request, not per-tool. Multiple tools don't increase the system overhead; a single tool_use block does. Tool definitions themselves add tokens: names, descriptions, and schemas are included in the `tools` parameter. `input_examples` add 20-50 tokens for simple examples, 100-200 for complex nested objects. For cost-sensitive applications, tool overhead can be significant on high-volume systems; designing comprehensive tool descriptions upfront pays off in reduced retry cost.

7. **Strict Tool Use Eliminates Schema Mismatches**
   - By default, Claude's tool calls may not conform to your schema. Setting `strict: true` on tool definitions guarantees that inputs will match your schema exactly, preventing missing parameters and type mismatches. When combined with `tool_choice: {"type": "any"}`, strict tool use guarantees both that a tool will be called AND that inputs will conform. This eliminates a class of errors where Claude makes reasonable guesses about missing parameters (e.g., inferring "New York" when location is unspecified), which may not match application expectations. The trade-off: strict tool use may cause the model to ask clarifying questions instead of making assumptions, reducing one-shot success rates for ambiguous prompts.

---

## Implementation Patterns

### The Client Tool Loop (Pseudocode)

```
messages = [{"role": "user", "content": user_query}]
while True:
    response = api.messages.create(
        model="claude-opus-4-7",
        max_tokens=1024,
        tools=[...],
        messages=messages
    )
    
    if response.stop_reason != "tool_use":
        return response.content  # end_turn, max_tokens, stop_sequence, refusal
    
    # Extract tool_use blocks and execute
    tool_results = []
    for tool_use_block in response.tool_use_blocks:
        result = execute_tool(tool_use_block.name, tool_use_block.input)
        tool_results.append({
            "type": "tool_result",
            "tool_use_id": tool_use_block.id,
            "content": result
        })
    
    # Continue conversation
    messages.append({"role": "assistant", "content": response.content})
    messages.append({
        "role": "user",
        "content": tool_results  # Tool results FIRST in content array
    })
```

### Tool Definition Template (Best Practices)

```json
{
  "name": "service_action_name",  // kebab-case, namespaced by service
  "description": "What the tool does and when to use it. Include caveats. 3-4+ sentences.",
  "input_schema": {
    "type": "object",
    "properties": {
      "param": {
        "type": "string",
        "description": "What this parameter means and how it affects the tool."
      }
    },
    "required": ["param"]
  },
  "input_examples": [  // For complex tools; demonstrates proper formatting
    {"param": "example_value"}
  ],
  "strict": true  // Enforce schema conformance
}
```

---

## Cross-References

**Related findings files** (within projects/agent-patterns/):
- [[building-effective-agents.md]]: Tool use is the primitive that the five core patterns (chaining, routing, parallelization, orchestrator-worker, evaluator-optimizer) build upon. Effective tool design is more impactful than sophisticated orchestration.
- [[multi-agent-systems-in-claude.md]]: Multi-agent systems extend tool use patterns; orchestrator agents and worker agents communicate through tool calls and results, forming hierarchies of delegation.

**Related orchestrator documents:**
- [SUPERVISOR.md](../../orchestrator/SUPERVISOR.md): Supervisor uses similar principles (transparency, iterative refinement) to debug agent failures; understanding tool loops helps diagnose where agents get stuck.

---

## Design Implications for Agent-Fleet-Skeleton

1. **Tool interface precedes orchestration.** The fleet should invest in clear, well-documented tool definitions before adding multi-agent complexity. A poorly designed tool library breaks even simple orchestration; excellent tools make any orchestration work reliably.

2. **Execution location (client vs. server tools) determines latency and cost.** Server tools (web_search, code_execution) are better for integrations outside the fleet's scope; client tools are better for business logic where the fleet controls execution. Mixed strategies are necessary for real-world systems.

3. **The agentic loop is where most failures happen.** Off-by-one errors in `tool_use_id` matching, incorrect content ordering in `tool_result` blocks, or mismatched schemas cause cascading failures. Strict tool use should be the default.

4. **Token overhead is real at scale.** For high-volume systems, tool definitions and system prompts account for hundreds of tokens per request. Consolidation (fewer, more capable tools) and descriptions that are precise without being verbose pay off.

---

## Status

✓ **Complete reference material on tool use mechanisms.** Sufficient detail to serve as reference for all orchestration patterns; provides foundation for understanding multi-agent delegation and error handling in tool loops.

**Next actions for fleet:**
- Findings on multi-agent systems will show how tool use extends to orchestrator-worker delegation and agent hierarchies.
- ReAct paper (Tier 3) will provide theoretical foundation for why the loop structure works and when it fails.
