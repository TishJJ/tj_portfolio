# ADR: LLM Tooling Selection — Prompts, Scripts, MCP, and Frameworks

**Status:** Accepted  
**Date:** June 2025  
**Author:** Tish Johnson  
**Domain:** AI Systems Architecture / Platform Engineering  
**Related:** SEVEN security toolchain, SAGE governance engine, ADR-001 adaptive task planner

---

## 1. Context

As LLM-native tooling has proliferated — prompt templates, MCP servers, agent frameworks, VS Code skills, local tools — the selection question has become genuinely difficult. The options overlap in capability. LangChain can do what a script can do. An MCP server can do what a prompt can do. The fact that a tool *can* handle a use case doesn't mean it *should*.

The common failure mode is reaching for tooling based on surface familiarity or because a task feels "AI-ish" — without first answering a more fundamental question: what role should the LLM play in this workflow, if any?

Tooling selection that skips the role question inherits whatever is wrong about the assumption underneath it. An agent framework applied to a task that needs a script doesn't make the task smarter — it makes the failure mode probabilistic instead of deterministic.

This ADR documents the decision framework for selecting between prompts, scripts, local tools, MCP servers, and LLM orchestration frameworks. It applies across any system where LLM capabilities are being composed with deterministic logic.

---

## 2. The Framework

### Step 1: Establish Decision Ownership

Before selecting any tooling, determine who or what owns each decision in the workflow.

**Deterministic ownership required** when:
- The same input must always produce the same output
- The decision is auditable or compliance-relevant
- Failure of the decision has downstream consequences that require a clear owner
- The decision is a gate — something that must pass or fail, not something that might pass or fail

**Probabilistic ownership acceptable** when:
- The task is inherently interpretive — synthesis, classification, summarization, reasoning over ambiguous inputs
- Variance in output is tolerable or desirable
- The decision benefits from contextual nuance that rules cannot fully encode

**The test:** Ask who gets blamed when the decision is wrong. That's who owns it. If the answer is "the LLM," reconsider whether probabilistic ownership is actually acceptable for this decision.

Decision ownership determines the LLM's role. Tooling follows from role — not the other way around.

---

### Step 2: Determine the LLM's Role

Given the ownership determination, the LLM's role is one of three:

**Executor** — the LLM's output is the decision or action. Appropriate only when probabilistic ownership is acceptable.

**Advisor** — the LLM provides analysis, interpretation, or opinion. A deterministic system owns the decision. The LLM's output is signal, not authority. This is underused and undervalued — LLM opinions alongside deterministic gates create training signal that can improve the gate over time.

**Excluded** — the LLM should not be in the execution path. Either the decision requires determinism the LLM cannot guarantee, or the data involved must not enter the LLM's context at all.

---

### Step 3: Select Tooling

With ownership and role established, tooling selection follows a clear decision tree.

**Is the LLM's output load-bearing in the workflow's control flow?**

If the workflow branches, gates, or routes differently based on what the LLM said — if probabilistic output drives conditional logic — the LLM is structural, not decorative. An orchestration framework is justified.

If the LLM is a boundary component only — pre-processing input before a deterministic pipeline, or post-processing output after one — simpler tooling is sufficient. The workflow itself doesn't depend on the LLM's output to know what to do next.

---

## 3. Tooling Selection Reference

### Prompt

**Use when:** LLM interpretation of the task is acceptable. The context and guidance provided are directional — it is fine if the LLM uses them partially or not at all. The probabilistic nature of the output is acceptable for this step.

Prompts are the right tool when you want to give the LLM latitude. If you find yourself engineering a prompt to constrain the LLM into deterministic behavior, that is a signal you need a different tool.

**Not appropriate when:** The output must be consistent, the data must not enter the LLM's context, or the LLM's interpretation of the output will drive a gate or decision that requires determinism.

---

### Script / Local Tool

**Use when:**
- Execution must be deterministic — same input, same output, every time
- All data is internal to the system (no external service boundary)
- The data must not be read or interpreted by the LLM for security reasons

The security case deserves emphasis. A secret scanner running as a local script doesn't expose secrets to the LLM — the LLM only invokes the script and receives a sanitized result. The LLM never reads the file. This is not just a determinism requirement; it is a confidentiality requirement. The distinction matters because even if you were comfortable with probabilistic handling of the task, you would still reach for a script to keep the data out of context.

Similarly: a deploy gate that evaluates whether a build is deployable should be a script. The logic is deterministic — deploy flag is true, trigger type supports deployment, vulnerability scan result meets environment-specific threshold. These are boolean conditions with auditable inputs. A script owns that decision. An LLM may advise on the result; it does not gate the deploy.

---

### MCP Server

**Use when:** The same criteria as a script or local tool apply — deterministic execution, data should not be interpreted by the LLM directly — but the data is external or crosses a system/trust boundary.

MCP is the right abstraction when the capability needs to be available to an LLM as a callable unit, but the implementation touches external systems, APIs, or data that should not be passed through the LLM's context. The LLM triggers the workflow as an atomic unit. It provides input, receives output, and may reason over the output. It does not orchestrate the steps inside the workflow.

This distinction is load-bearing: the LLM interacts with workflows as atomic units. It is a consumer of workflow output and optionally a producer of workflow input. It is never the coordinator of workflow internals.

**Example:** A security scan workflow — lint, SAST, dependency scan — is available as an MCP capability. The LLM calls `run_security_scan(code)` and receives a structured result. It does not trigger lint, read the result, trigger SAST, read that result, and so on. The scan is a black box from the LLM's perspective. The LLM reasons over the output; it does not manage the execution.

---

### LLM Framework (LangChain, LlamaIndex, etc.)

**Use when:** The LLM's probabilistic output is load-bearing in the workflow's control flow. The workflow branches, gates, or routes based on what the LLM said. The LLM is structural — not a capability bolted onto the edges of a deterministic pipeline, but a component the pipeline depends on to know what to do next.

A framework is justified when you need orchestration that handles state, conditional logic, retry, and the LLM being in the middle of that — because you have designed the system to depend on the LLM's output at multiple decision points.

**Not justified when:** The LLM is only at the boundary — summarizing input before a deterministic process, or explaining output after one. In that case, the framework's abstractions are overhead. A direct API call, a script, or an MCP server is simpler and more appropriate.

**Lightweight vs. full framework:** If you have one or two conditional branches that depend on LLM output, a lightweight approach (direct API calls with conditional logic) beats a full framework. If you have complex multi-step workflows where LLM output drives branching at multiple points, the orchestration complexity justifies the framework's abstractions.

---

## 4. Decision Ownership and LLM Opinion Are Separate Questions

The most important clarification in this framework: who owns a decision and who may offer an opinion about it are different questions with different answers.

A deployment gate is owned by a deterministic system — it evaluates boolean conditions against defined rules. The LLM does not own that decision and should not be in the execution path that makes it.

But the LLM may offer an opinion on the same data. If the gate passes a build that the LLM would flag as risky, that is useful signal. Collected over time, it becomes training data. It may inform a future adjustment to the gate's rules. The LLM earns influence over the decision logic through accumulated signal — not through being in the decision path on any individual run.

This framing resolves a tension that often paralyzes tooling decisions: "but the LLM would be good at this." It may be. That doesn't mean it should own the decision. Advisor and executor are different roles. A system can use LLM analysis extensively while keeping LLM output out of any gate that requires determinism.

The two reasons to exclude the LLM from execution are distinct and both valid:

1. **The decision requires determinism** — probabilistic output is not acceptable for this gate or action
2. **The data requires confidentiality** — the information must not enter the LLM's context regardless of how the output would be used

---

## 5. Consequences

**Clarity on system boundaries.** When decision ownership is established before tooling is selected, the system boundary between deterministic and probabilistic components becomes explicit. This makes the system easier to audit, debug, and evolve. Failures have clear owners.

**Appropriate use of LLM capabilities.** LLMs are genuinely valuable as advisors — for interpretation, synthesis, and analysis alongside deterministic systems. Keeping them out of gates they shouldn't own doesn't diminish their value; it clarifies where their value actually is.

**Reduced framework overhead.** Most workflows that reach for an agent framework don't need one. The LLM is a boundary component, not a structural one. Recognizing this earlier reduces complexity and makes probabilistic failure modes more visible.

**Security by design.** Treating data confidentiality as a first-class reason to reach for a script or MCP — not just determinism — prevents a class of accidental exposure where secrets or sensitive data enter the LLM's context because the tooling choice didn't consider what the LLM would need to read to do its job.

**LLM opinions as training signal.** When LLM advisors operate alongside deterministic gates, the divergences between them are data. A gate that consistently disagrees with LLM analysis is either correctly constraining probabilistic output, or it has rules that need refinement. That signal is only visible if the roles are separated.

---

## 6. Observed Failure Modes This Framework Prevents

**"The LLM didn't run the scan."** An agent is given responsibility for a security workflow. It sometimes calls the scan tool, sometimes doesn't, depending on context and confidence. The scan is non-deterministic because the trigger is. Fix: the scan is a CI step with a deterministic trigger. The LLM may call it as a tool when drafting code; it does not own the gate.

**"The deploy went out with a failing scan."** The LLM was in the deployment decision path. It evaluated the scan result, concluded the failure was low-severity, and approved the deploy. A probabilistic system made a gate decision. Fix: the gate is a script. The LLM may flag low-severity findings for human review; it does not approve deploys.

**"The LLM read the secrets."** A script was replaced with a prompt-based tool that asked the LLM to sanitize sensitive files. The LLM processed the file, including the secrets, before sanitizing. The data was in context. Fix: sanitization is a script. The LLM invokes it and receives a sanitized result. It never reads the file.

**"We added LangChain and it got slower and harder to debug."** A workflow with one LLM call at the end was refactored to use an agent framework because the task felt AI-native. The LLM was always a post-processor; it was never structural. Fix: the framework adds overhead without adding capability when the LLM is a boundary component. A direct API call is simpler.

---

## 7. AI Collaboration Disclosure

This ADR was documented with Claude (Anthropic) acting as a Socratic dialogue partner and synthesis engine. The nature of the collaboration here was different from technical decision ADRs where AI may suggest approaches or alternatives.

**What the framework is and where it came from:** The decision framework — ownership before role, role before tooling, the three-zone model, the distinction between determinism and confidentiality as separate exclusion reasons, the separation of decision ownership from opinion generation — emerged entirely from the author's thinking during a structured dialogue. Claude asked clarifying questions and reflected the framework back at each stage to confirm fidelity. It did not suggest the framework or its components.

**What Claude did:** Synthesized a framework from a conversation that moved through examples — security scans, deployment gates, secret handling — and extracted the generalizable structure underneath them. Compressed and documented that structure into ADR format. Identified when the framework was complete enough to draft. Organized the failure modes section from examples raised during the dialogue.

**What Claude did not do:** Propose the decision axes. Suggest the ownership-first sequencing. Identify the confidentiality/determinism distinction as two separate reasons to exclude an LLM. Articulate the advisor role as underused. Those came from the author.

**Why this is disclosed:** The same reason as the DuckDB ADR — intellectual honesty about AI use is a signal, not a liability. The more relevant signal here: a practitioner who can articulate a novel framework in natural language, through examples, and have it compress cleanly into a structured document has the framework. AI accelerated the documentation. It did not produce the thinking.

---

## 8. Reflection

This framework emerged from observing what breaks when tooling is selected before ownership is established. The failures are consistent: gates become suggestions, security boundaries become advisory, and debugging becomes probabilistic because the failure point is probabilistic.

The underlying principle is not specific to LLMs. It applies to any system where you are composing components with different reliability characteristics. Know what each component is responsible for deciding. Know what it is allowed to see. Then select the tool that matches those constraints.

For LLMs specifically, the advisor role is underused. There is a tendency to treat LLM involvement as binary — either the LLM does the thing or it doesn't. The more useful design is: the LLM interprets, flags, and builds signal alongside deterministic systems that own the gates. Over time, that signal informs the gates. The LLM earns influence through evidence, not through being in the execution path.

That is a more durable architecture than one where the LLM owns decisions it cannot reliably make, and it is a more valuable one than one where the LLM is excluded from any meaningful role.

---

*Part of the `tj_portfolio` case study series. The SEVEN security toolchain and SAGE governance engine implement this framework in production contexts. See also: deployment gate architecture, triple-gate governance model.*