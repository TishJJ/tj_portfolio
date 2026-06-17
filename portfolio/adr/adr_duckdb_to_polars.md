# ADR: DuckDB httpfs → Two-Pass Polars/PyArrow Architecture

**Status:** Accepted  
**Date:** June 2025  
**Author:** Tish Johnson  
**Domain:** Data Engineering / Memory-Constrained Processing  
**AI Collaboration Disclosure:** Yes — see Section 6

---

## 1. Context

### The Problem

Find all NYC Yellow Taxi TLC trips above the p90 trip distance threshold across the full historical dataset (2009–present), approximately 1.5 billion rows, within a 4GB RAM constraint. The data lives on `archive.org` as Parquet files partitioned by month/year.

### Why This Was Hard

Three distinct failure modes collapsed the naive approaches:

**CloudFront rate limiting.** `archive.org` sits behind CloudFront. Iterating Parquet files with naive HTTP access triggered rate limiting mid-run — not immediately, but after enough sequential requests that the failure appeared intermittent. This made debugging non-obvious. The error wasn't "you're rate-limited"; it was silent corruption or stalled downloads.

**OOM kills in both Colab tiers.** A 4GB Colab environment OOM-killed the process during the full-dataset scan. Upgrading to a 12GB environment also OOM-killed — because the approach hadn't changed, only the headroom. Throwing resources at a design problem doesn't fix the design.

**tdigest memory pathology.** The initial plan used `tdigest` for streaming p90 estimation. Under the full dataset, tdigest's memory growth was unbounded in practice — it compressed less aggressively at extreme quantile positions and accumulated centroid state across 1.5B rows. The library's guarantees didn't hold at this scale.

### Constraints (Non-Negotiable)

- 4GB RAM ceiling (Colab free tier target)
- No local storage — files accessed over HTTP
- Resume-capable — rate limiting could interrupt at any point
- p90 accuracy within tolerable error for outlier identification (not financial-grade precision)
- Single-machine — no distributed compute

---

## 2. Decision

**Adopted architecture: Two-pass PyArrow `iter_batches` + Polars lazy scan with numpy reservoir sampling.**

### Pass 1 — Threshold Estimation (PyArrow iter_batches)

Stream each Parquet file in fixed-size batches using PyArrow's `iter_batches`. Maintain a fixed-size reservoir sample (numpy, ~100K elements) using Vitter's Algorithm R. After processing all files, compute p90 from the reservoir. Memory footprint is bounded by reservoir size, not dataset size.

### Pass 2 — Outlier Extraction (Polars lazy scan)

Use Polars lazy scan with predicate pushdown against the computed threshold. Polars pushes the filter to the file-read layer, minimizing memory load. Only rows above p90 are materialized. Output written incrementally.

### Resume Capability

Progress tracked in a checkpoint file (processed file list + partial reservoir state). On restart, skip processed files and restore reservoir. CloudFront interruptions are recoverable without restarting from zero.

---

## 3. Alternatives Considered

### Option A: DuckDB httpfs

**What it is:** DuckDB can query remote Parquet files directly via its `httpfs` extension. A single SQL query would handle the full pipeline.

**Why it was appealing:** Elegant. One query. DuckDB's execution engine is columnar and memory-efficient. This was the first serious option evaluated.

**Why it failed:**  
DuckDB `httpfs` loads metadata and potentially entire row groups depending on statistics availability. At 1.5B rows across hundreds of remote Parquet files, the query planner couldn't bound its memory usage — it optimized for query performance, not memory ceiling. The 4GB environment OOM-killed before the query completed.

More fundamentally: DuckDB's memory model is designed for local files or high-bandwidth object storage. `archive.org` via CloudFront is neither. The latency profile broke DuckDB's prefetch assumptions.

**What this revealed:** Tool-problem fit matters more than tool capability. DuckDB is excellent. It was the wrong tool for this constraint set.

### Option B: Single-Pass Polars with Lazy Scan

**What it is:** Use Polars lazy evaluation across all files in a single pass, letting Polars handle memory management.

**Why it failed:** Polars lazy scan streams, but materializing a global p90 requires holding enough state to compute a true quantile. Polars' `quantile` in lazy mode either approximates (trading accuracy) or buffers (OOM). At 1.5B rows, this wasn't stable.

### Option C: tdigest Streaming Estimation

**What it is:** `tdigest` is a streaming quantile algorithm designed for exactly this use case — accurate quantile estimation with bounded memory.

**Why it failed in practice:** tdigest's compression is tunable, but at extreme scale with non-uniform distance distributions (the TLC data includes spatial outliers, short trips, airport runs), the centroid count grew beyond expected bounds. Memory wasn't technically unbounded — but it was unbounded relative to the 4GB ceiling. The library's guarantees assume more uniform distributions than this dataset exhibits.

**What replaced it:** numpy reservoir sampling. Simpler, predictable memory use, accuracy empirically validated at < 0.08% error at p90 across five benchmark runs.

### Option D: Two-Pass PyArrow + Polars (Adopted)

Described above. Selected because each component does exactly one job within proven memory bounds: PyArrow streams batch-by-batch, reservoir sample is fixed-size by construction, Polars pushes the filter down, output is written incrementally.

---

## 4. Consequences

**Performance:** 56.7x speedup over the original naive approach. Hot-path simulation at 211x under optimal conditions (pre-warmed HTTP connections, cached CloudFront responses).

**Accuracy:** Reservoir sample error < 0.08% at p90 across benchmark runs. Sufficient for outlier identification; would require adjustment for financial or regulatory use.

**Operability:** Resume capability made the CloudFront rate limiting a nuisance rather than a blocker. Checkpoint state is human-readable JSON.

**Complexity cost:** Two passes mean two HTTP sweeps across the dataset. For datasets that change between passes, this introduces a consistency window. For the static TLC historical archive, this is not a concern. For live or frequently-updated data, it would be.

**Portability:** The architecture assumes HTTP-accessible Parquet. Adapting to S3, GCS, or local files requires only minimal connector swaps — the core logic doesn't change.

---

## 5. Benchmarks

| Approach | Relative Speed | Memory Profile | Resume Capable |
|---|---|---|---|
| DuckDB httpfs | Baseline | OOM at 4GB | No |
| Single-pass Polars | ~1x | OOM at 4GB | No |
| tdigest streaming | ~1x | Unstable > 100M rows | Partial |
| Two-pass PyArrow + Polars | **56.7x** | Stable at 4GB | Yes |
| Hot-path (warmed) | **211x** | Stable at 4GB | Yes |

Benchmarks from five-run suite. Variance < 8% across runs.

---

## 6. AI Collaboration Layer

This section documents the role of Claude (Anthropic) as a Socratic thinking partner during this decision process. I'm including it because intellectual honesty about AI use is, itself, a signal — and because the distinction between AI-assisted reasoning and AI-generated reasoning matters, especially in a portfolio context.

### What Claude Suggested and I Adopted

**Reservoir sampling as tdigest replacement.** When tdigest failed, Claude suggested reservoir sampling with Vitter's Algorithm R as the fix. I adopted this without modification. The reasoning was sound: fixed-size reservoir, O(n) streaming, no distribution assumptions. The implementation matched the suggestion closely.

**PyArrow `iter_batches` as the streaming primitive.** Claude identified `iter_batches` as the right abstraction for bounded-memory Parquet streaming. I was familiar with PyArrow but hadn't worked with `iter_batches` specifically. I adopted it and it held up.

**Checkpoint file as resume strategy.** The specific pattern — write processed filenames + serialized reservoir state to JSON — came from Claude. I adopted the pattern, modified the schema slightly to include a timestamp field for debugging purposes.

### Where Claude Suggested and I Modified

**The error interpretation for tdigest.** Claude's initial read was that tdigest was failing due to implementation bugs or version incompatibility. I pushed back: the failure pattern was too consistent across versions to be a bug. The memory growth under non-uniform distributions was a known tdigest limitation at extreme scale. Claude updated its interpretation after I described the centroid accumulation pattern. The final understanding was collaborative, but the initial diagnostic instinct was mine.

**DuckDB framing.** Claude initially framed DuckDB's failure as a configuration problem — tune the memory limit, adjust prefetch settings. I disagreed. The failure wasn't misconfiguration; it was tool-problem mismatch. DuckDB's memory model isn't designed for high-latency HTTP with rate-limiting intermediaries. I held this position, Claude eventually agreed, and we stopped pursuing DuckDB tuning. This saved probably four hours of configuration debugging.

**Polars lazy scan placement.** Claude suggested Polars lazy scan for Pass 1 (threshold estimation). I moved it to Pass 2 (outlier extraction) and used PyArrow `iter_batches` for Pass 1. My reasoning: Polars lazy quantile computation requires materializing more state than a fixed reservoir. The reservoir approach is simpler and has predictable memory. Claude's instinct was right about lazy evaluation — wrong about where to apply it.

### Where I Arrived Independently and Claude Confirmed

**CloudFront as the rate-limiting source.** I identified CloudFront from the HTTP response headers before raising it with Claude. The failure looked intermittent, which is a CloudFront signature — it rate-limits based on request velocity, not connection count, so sequential loops look like abuse. Claude confirmed the diagnosis but didn't surface it.

**"OOM kills mean the design is wrong, not the resources."** After the 12GB Colab OOM, my instinct was: this isn't a resources problem, it's a design problem. Adding RAM to a fundamentally unbounded algorithm doesn't fix the algorithm. Claude agreed, but I got there first. This reframe was the inflection point that unlocked the two-pass architecture.

**Health checks can lie; remediation is not resolution.** During debugging, I articulated a principle: a process that reports healthy while accumulating state toward OOM is a process whose health check is lying. The fix isn't better monitoring — it's bounding the state. Claude recognized this as a systems principle with broader applicability. I brought the observation; Claude helped name and extend it.

### What This Reveals About LLMs as Reasoning Partners

Claude was most useful as a constraint-checker and option-generator: "have you considered X," "what happens to Y when Z." This is genuinely valuable — not because the options were always right, but because enumerating options fast under pressure is hard when you're also debugging.

Claude was least useful when the diagnosis required domain-specific intuition: recognizing CloudFront's rate-limiting signature, understanding why tdigest degrades under skewed distributions, knowing that DuckDB's prefetch assumptions break under high-latency HTTP. These required pattern-matching from prior experience, not option generation.

The collaboration worked because I pushed back. When Claude's initial diagnosis was wrong, I held my position. A practitioner who defers to AI on the diagnosis phase — who treats AI output as authoritative rather than as a prompt for further reasoning — would have wasted time on the wrong paths.

**The meta-point:** Using AI as a Socratic partner is a skill. It requires knowing when to adopt, when to modify, and when to override. The outputs here — the two-pass architecture, the reservoir design, the checkpoint pattern — were shaped by that skill. They weren't generated by Claude and accepted wholesale.

---

## 7. Reflection

### On the Technical Decision

The right architecture here was obvious in retrospect. Two-pass, bounded reservoir, predicate pushdown — these are standard memory-constrained processing patterns. The difficulty wasn't the solution; it was recognizing which failures were design failures versus resource failures, and being willing to throw away working-but-wrong approaches.

The tdigest detour cost time but wasn't wasted: it confirmed that streaming quantile libraries have distribution assumptions that don't hold in practice at extreme scale. That knowledge transfers.

### On the AI Collaboration Disclosure

Disclosing AI use in a portfolio document is unusual. I'm doing it deliberately, for two reasons.

First, it's accurate. Pretending this was fully solo would misrepresent the process. Claude was a Socratic partner during the decision-making. The thinking is mine; the dialogue shaped the thinking.

Second, the ability to collaborate effectively with AI — to know what to adopt, what to modify, and what to override — is itself a principal-level skill. Hiding it doesn't signal independence; it signals a failure to understand what's actually being evaluated.

The distinction that matters isn't "did you use AI" — it's "whose judgment shaped the outcome." The answer here is clear. The thesis (design failures masquerade as resource failures), the key diagnostic insights (CloudFront signature, tdigest distribution assumptions, DuckDB memory model mismatch), and the architectural override (reservoir in Pass 1, not Polars lazy scan) were mine. Claude helped me move faster and think out loud. It didn't provide the judgment.

That distinction is what this ADR documents.

---

*Part of the `tj_portfolio` case study series. See also: Flask thread pool exhaustion diagnostic lab, n8n signal triage architecture, Tinybird Parquet pipeline benchmark.*