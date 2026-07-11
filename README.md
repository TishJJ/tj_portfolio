# Tish Johnson — Engineering Portfolio

Principal Platform Architect and Solutions Engineer specializing in the intersection of platform engineering, AI systems governance, and DevSecOps. My work centers on a single thread: **deterministic control over probabilistic or chaotic systems** — making complex systems safer, faster, and easier to operate at scale.

This portfolio documents real work: decisions made under constraint, tradeoffs considered, failure modes analyzed, outcomes measured.

---

## Case Studies

### [CI/CD Migration & Governance Platform](./portfolio/case-studies/cicd_governance_platform.md)
*Platform Engineering · IDP · DevSecOps · GitHub Actions*

Inherited a CI/CD migration 12+ months behind schedule with no governance model and no security visibility. Designed and delivered a hybrid stub workflow architecture — 6 central workflows governing 200+ repositories — achieving a 107% increase in automated deployments, 50% faster releases, and 75% reduction in pipeline complexity.

**Key outcomes:** 107% deployment increase · 50% faster releases · 75% complexity reduction · ~90% security coverage · 25% vulnerability reduction

---

### [Governance Is Not a Gate — It's an Acceleration Layer](./portfolio/case-studies/governance_not_a_gate.md)
*Platform Engineering · DevSecOps · Pipeline Architecture · Policy Enforcement*

The gate model assumes two systems: delivery and governance. One builds and ships. The other reviews and approves. The handoff between them is where velocity goes to die. This piece documents a three-stage model for collapsing those two systems into one.

**Stage 1 — Enforce:** Governance becomes an execution layer. Controls are embedded in the pipeline, not scheduled separately. Policy is present from the first commit. Teams can't accidentally skip required controls — they're not optional.

**Stage 2 — Measure:** Embedded controls generate structured output (SBOM, SARIF). That output becomes the signal for trending — not just "are we scanning" but "is our posture improving." Metrics include Mean Time to Clean Commit and Time to First Clean Commit.

**Stage 3 — Predict:** SCA signal from Stage 2 trains a recommendation engine that guides library selection before a dependency is committed. IDE integration moves the intervention earlier still. Change selection rate measures prevention at the exact point it happens.

The connecting insight: treating pipeline execution as a data problem — not a process problem — makes governance retroactively queryable. A new policy applied against captured execution data answers a new question about what already happened without re-instrumenting anything.

---

## Architecture Decision Records

ADRs documenting technical decisions made under real constraints — with tradeoffs, alternatives considered, and where reasoning led. Includes explicit disclosure of AI collaboration where relevant.

### [LLM Tooling Selection — Prompts, Scripts, MCP, and Frameworks](./portfolio/adr/adr_llm_tool_selection.md)
*AI Systems Architecture · Platform Engineering*

A decision framework for choosing between prompts, scripts, local tools, MCP servers, and LLM orchestration frameworks. The central insight: establish decision ownership before selecting tooling. Who owns the decision — and what data the LLM is allowed to see — determines the right tool. Tooling selected before ownership is established inherits whatever is wrong about the assumption underneath it.

**Core framework:** Decision ownership → LLM role (executor / advisor / excluded) → tooling selection

---

### [DuckDB httpfs → Two-Pass Polars/PyArrow Architecture](./portfolio/adr/adr_duckdb_to_polars.md)
*Data Engineering · Memory-Constrained Processing · AI Collaboration Disclosure*

Documents the decision to move from DuckDB httpfs to a two-pass reservoir sampling architecture for processing 1.5B+ NYC Yellow Taxi TLC records within a 4GB RAM constraint. Includes an explicit AI collaboration layer documenting where Claude was adopted, modified, or overridden — and what that reveals about using LLMs as reasoning partners versus solution generators.

**Key outcomes:** 56.7x speedup · reservoir error < 0.08% at p90 · resume-capable · 4GB RAM stable

---

## Diagnostic Labs

Hands-on failure analysis with reproducible environments, layered evidence, and documented resolution methodology. Code and scripts included.

### [Thread Pool Exhaustion — Failure Mode Analysis](portfolio/labs/thread_pool_exhaustion/failure_mode_analysis.md)

*Systems Reliability · Failure Analysis · Flask · Gunicorn*

A Flask API under concurrent load fills its thread pool entirely — every thread blocked waiting for an upstream that never returns. The service reports healthy throughout: process running, port listening, `/health` returning 200. Standard monitoring never fires. This lab reproduces the failure deterministically, traces it through process state, syscall behavior, and network state, and documents the distinction between remediation (clearing blocked threads) and resolution (fixing the design).

**Key insight:** Health checks are a contract, not a guarantee. Proactive drift detection on leading indicators — thread utilization, P90 latency, connection state — catches this class of failure before the health check knows anything is wrong.

**[→ Full lab with reproduction and resolution scripts](portfolio/labs/thread_pool_exhaustion)**

---

## External Projects

### [NYC Yellow Taxi — Distance Outlier Finder](https://github.com/TishJJ/TB_TakeHome)
*Data Engineering · Python · Polars · PyArrow*

Find all NYC yellow taxi trips above the 90th percentile of trip distance across the full TLC historical dataset (2009–present, 1.5B+ rows). Solved real production constraints: CloudFront rate limiting blocking naive download approaches, OOM kills on both 4GB and 12GB environments. Implemented a two-pass architecture — PyArrow `iter_batches` reservoir sampling for threshold estimation, Polars lazy scan with predicate pushdown for outlier extraction.

**Key outcomes:** Full TLC dataset within 4GB RAM · reservoir error < 0.08% at p90 · resume-capable across interrupted runs · 56.7x speedup over original approach

---


## Connect

- **Web:** [innozatesolutions.com](https://www.innozatesolutions.com)
- **LinkedIn:** [linkedin.com/in/tishjj](https://linkedin.com/in/tishjj)
- **GitHub:** [github.com/TishJJ](https://github.com/TishJJ)
