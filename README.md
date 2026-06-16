# Tish Johnson — Engineering Portfolio

Principal Platform Architect and Solutions Engineer with 10+ years designing systems that reduce operational risk at scale. I specialize in IDP architecture, CI/CD governance, and customer-facing technical advisory — the intersection of platform engineering and consulting.

This portfolio documents real work: decisions made under constraint, tradeoffs considered, outcomes measured.

---

## Case Studies

### [CI/CD Migration & Governance Platform](./portfolio/case-studies/cicd_governance_platform.md)
*Platform Engineering · IDP · DevSecOps · GitHub Actions*

Inherited a CI/CD migration 12+ months behind schedule with no governance model and no security visibility. Designed and delivered a hybrid stub workflow architecture that now powers 200+ repositories with 6 central workflows — achieving 107% increase in automated deployments, 50% faster releases, and 75% reduction in pipeline complexity.

**Key outcomes:** 107% deployment increase · 50% faster releases · 75% complexity reduction · 90% security coverage · 25% vulnerability reduction

---

### [Failure Mode Analysis — Thread Pool Exhaustion](./portfolio/labs/thread_pool_exhaustion/failure_mode_analysis.md)
*Systems Reliability · Failure Mode Analysis · Observability · Docker*

A production-realistic failure scenario: a Flask/Gunicorn API with a missing timeout exhausts its thread pool under concurrent load while the health check continues returning 200. Full diagnostic methodology — process level, syscall level, network level — plus a structured 5-step resolution workflow. Includes runnable lab with reproduction and resolution scripts.

**Key insights:** Health checks can lie · Remediation is not resolution · SPC framing for proactive drift detection · Fault mode analysis applied to software design

---

### [Why Stub Workflows Are a Force Multiplier](./portfolio/case-studies/why_stub_workflows.md)
*Architecture Patterns · Platform Engineering · Developer Experience*

A practitioner's guide to the stub workflow pattern — how a small platform team can govern hundreds of repositories without burnout, and why the pattern generalizes beyond GitHub Actions to API gateways, Kubernetes operators, and control plane/data plane separation.

**Key insight:** 6 central workflows supporting 200+ repositories. Onboarding time reduced from 1-2 weeks to minutes.

---

### [NYC Yellow Taxi — Distance Outlier Finder](https://github.com/TishJJ/TB_TakeHome)
*Data Engineering · Python · Polars · PyArrow*

Technical assessment project: find all NYC yellow taxi trips above the 90th percentile of trip distance across every monthly Parquet file published by the TLC (1.5B+ rows). Solved real production constraints — CloudFront blocking, OOM kills on 4GB and 12GB environments — using a two-pass reservoir sampling architecture with Polars lazy scan pushdown.

**Key outcomes:** Processes full TLC dataset (2009–present) within 4GB RAM · Reservoir sample error < 0.08% at p90 · Resume-capable across interrupted runs

---

## Writing

### [Governance Is Not a Gate — It's an Execution Layer](./portfolio/case-studies/governance_not_a_gate.md)
*Platform Philosophy · DevSecOps · Developer Experience*

Most enterprises treat governance as an external review process. That model creates friction, delays, inconsistency, and blind spots. Modern governance should be enforced through execution — embedded, observable, measurable, and developer-aligned.

---

## Contact

- **LinkedIn:** [linkedin.com/in/tishjj](https://linkedin.com/in/tishjj)
- **GitHub:** [github.com/TishJJ](https://github.com/TishJJ)