# Case Study: Failure Mode Analysis — Thread Pool Exhaustion

## The Scenario

A Flask API served by Gunicorn with a fixed thread pool of 10 threads. One route calls an internal upstream with no timeout configured. Under concurrent load the thread pool fills entirely with threads blocked waiting for a response that never returns in time. Every new inbound request is immediately rejected with a 503.

The service appears healthy throughout. The process is running, the port is listening, `/health` returns 200. Standard monitoring, load balancer health checks, and container orchestration liveness probes all report the service as up while 100% of real user traffic is failing. Automated recovery never triggers.

**[Full lab with reproduction and resolution scripts →](https://github.com/TishJJ/tj_portfolio/tree/main/portfolio/labs/thread_pool_exhaustion)**

---

## Why This Scenario

This scenario was chosen deliberately over simpler alternatives (network contention, memory leak, OOM kill) because it demonstrates three properties that matter most in production failure analysis:

**1. It looks like nothing is wrong**

The health check passes. The process is running. Metrics that most teams instrument — CPU, memory, process uptime — are all normal. The failure is entirely in thread state, which is invisible unless you know to look for it. Most monitoring setups would never catch this.

This is the class of failure that causes the longest outages — not because it's hard to fix, but because it's hard to see.

**2. The evidence self-clears**

Thread exhaustion can build gradually under load and partially resolve once connections time out or clients give up. The system may appear to recover on its own. Teams dismiss it as a transient blip. The next time load spikes, it happens again.

This is why I reach for Statistical Process Control framing when thinking about reliability. SPC identifies when a process is drifting *before* it fails outright. The equivalent in software is instrumenting on leading indicators — latency distribution, thread utilization, connection queue depth — not just binary up/down health. By the time the health check fails, you've already missed the window to observe the root cause.

**3. Remediation is not resolution**

Clearing blocked threads restores service. It is a valid emergency action. It is not root cause.

Adding `timeout=2` is the root cause fix — but even that is incomplete without asking what the application *should* do when the upstream is slow. A timeout without a fault handling strategy is just a faster failure. The real design conversation is:

| Option | Tradeoff |
|--------|----------|
| Timeout + return 503 | Fail fast and honest, but still a bad user experience |
| Timeout + retry with backoff | Adds resilience, but can amplify load on a struggling upstream |
| Timeout + circuit breaker | Stops calling a failing upstream until it recovers |
| Timeout + fallback response | Degrades gracefully with cached or partial data |

Asking *"what did we assume would never happen, and was that the right assumption?"* is as important as finding the smoking gun. This is fault mode analysis applied to software design — not just fixing what broke, but understanding what the system should do when things go wrong.

---

## How I Approached It

**Chose the scenario for signal density, not simplicity**

I evaluated multiple failure scenarios before selecting thread pool exhaustion. The selection criteria: real production occurrence rate, diagnostic complexity, and how many distinct principles the scenario forces you to engage with. Thread exhaustion scores high on all three. It requires process-level, syscall-level, and network-level observation simultaneously — which means the diagnostic methodology is the proof of depth, not just the fix.

**Reproduced it deterministically before diagnosing**

Before attaching any diagnostic tools I built a reproducible environment: three Docker containers (api-server, load-gen, shared network), scripted reproduction that induces the failure consistently, and a baseline capture before load starts. You cannot diagnose what you cannot reproduce. You cannot trust a fix you cannot verify.

**Followed the evidence layer by layer**

1. Process level (`ps -eLf`) — thread count climbs and plateaus. Confirms resource exhaustion, not a crash.
2. Syscall level (`strace -p <worker_pid> -f`) — every thread blocked on `recvfrom()` simultaneously. The smoking gun.
3. Network level (`ss -tip`) — CLOSE-WAIT dominates. The client gave up; the thread never did.

Each layer corroborates the previous one. The diagnosis isn't "I found a missing timeout" — it's "I traced the failure from symptom through process state through syscall behavior through network state and the evidence at every layer points to the same root cause."

**Separated remediation from resolution in the fix workflow**

The resolution script follows five explicit steps: update the code, validate in QA, deploy to production, restart cleanly, re-run the failure scenario and verify. The QA step is intentionally separate from production deployment — a passing test gate is required before promotion. This reflects how I think about any fix: the patch is not done when it works locally, it's done when it passes the same conditions that caused the original failure.

---

## What This Reveals About Production Systems

**Health checks are a contract, not a guarantee**

A health check that only verifies process liveness and port availability is telling you the minimum possible thing. It says the server is alive. It says nothing about whether it can serve traffic. In this scenario, a health check that measured thread availability or request success rate would have detected the failure immediately. Most systems don't instrument at that layer until after an outage teaches them to.

**The double-thread consumption pattern mirrors distributed callbacks**

In this scenario `/data` calls `/slow` on the same process. Each request consumes two threads simultaneously — one waiting to call, one serving the call. This halves the effective pool capacity. It looks like an implementation bug, but the pattern is structurally identical to distributed callback architectures where a service calls out and the far end calls back in. The resource accounting problem is the same. The fix is the same. Recognizing the pattern transfers.

**Proactive drift detection beats reactive alerting**

The failure builds gradually. Under light load the system works. Under sustained concurrent load it degrades and then collapses. The degradation phase — where latency is climbing but the health check still passes — is the window where SPC-style leading indicators would catch it. P90 latency trending up over 30 minutes is a different alert than "service is down." The first gives you time to act. The second means the outage is already happening.

---

## Artifacts

**[Lab repository →](https://github.com/TishJJ/tj_portfolio/tree/main/portfolio/labs/thread_pool_exhaustion)**

```
lab/
├── README.md               ← full technical write-up with methodology
├── repro_issue.sh          ← induces the failure, captures evidence
├── resolve_issue.sh        ← 5-step fix workflow, confirms recovery
├── repro_issue.ps1         ← Windows equivalent
├── resolve_issue.ps1       ← Windows equivalent
├── docker-compose.yml
├── api-server/
│   ├── app.py              ← buggy version (no timeout)
│   ├── app_fixed.py        ← production fix (timeout=2)
│   └── Dockerfile
├── load-gen/
│   └── load_gen.py
└── artifacts/              ← populated at runtime
    ├── evidence.log        ← strace + ss + fd count during failure
    └── fix.log             ← 5-step resolution log, before/after stats
```

---

## Reflections

### What this type of analysis requires

Failure mode analysis requires a different mental posture than feature development. You're not building toward a goal — you're working backward from a symptom. The discipline is resisting the urge to jump to a fix before you understand the mechanism. A fix applied to a misdiagnosis doesn't hold.

The other discipline is separating what you observe from what you infer. `strace` shows threads blocked on `recvfrom()`. That's an observation. "The missing timeout is causing thread exhaustion" is an inference. The inference is correct here, but it should be corroborated — which is why the methodology moves through three independent layers of evidence before concluding.

### What I'd instrument differently in production

- Thread utilization as a first-class metric, not just CPU and memory
- P90/P99 latency per route, not just aggregate error rate
- Connection state distribution (`ss` output) as a periodic diagnostic signal
- Alert on thread pool saturation percentage, not just on failure rate

### The design question that matters more than the fix

What should this system do when the upstream is slow? The timeout is the minimum viable answer. The circuit breaker is the production answer. The fallback response is the user experience answer. Which one you implement depends on the business requirement — but you have to ask the question before you close the incident.