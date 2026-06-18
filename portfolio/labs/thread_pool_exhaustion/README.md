# Thread Pool Exhaustion — Diagnostic Lab

## Why This Scenario

This scenario was chosen deliberately, not arbitrarily. Three properties
make it representative of real production failures:

**1. The Optimistic Developer**
Optimistic application design frequently omits edge case handling —
specifically, what happens when a dependency does not respond within
an acceptable window. Missing timeouts are not a sign of incompetence;
they are a natural consequence of building for the happy path first.
This class of bug exists in production systems across every industry.

**2. The Ghost in the Machine**
Thread exhaustion can build gradually under load and partially resolve
once connections time out or clients give up. The system may appear to
recover on its own, leading teams to dismiss the event as a transient
blip. The only way to establish root cause is to examine the environment
while the failure is actively occurring. This scenario demonstrates why
timing and live observation matter — as well as considering more proactive
approaches to capturing system behavior when it deviates outside expected
bounds. Much like Statistical Process Control identifies when a process
is drifting before it fails outright, instrumenting systems to alert on
anomalous latency, error rate, or resource consumption trends gives teams
the opportunity to catch these failures early rather than reactively.
Post-mortem log review alone is insufficient when the evidence
self-clears before anyone looks.

**3. The Lying Health Check**
Throughout the failure `/health` returns HTTP 200. The process is
running, the port is listening, the endpoint responds. Standard
monitoring, load balancer health checks, and container orchestration
liveness probes all report the service as healthy while 100% of real
user traffic is failing. Automated recovery never triggers. The outage
persists until a human notices the symptom, catches it while it is
happening, and inspects process state before threads drain and the
system temporarily self-corrects.

**4. Remediation Is Not Resolution**
Clearing blocked threads during the event will restore service in that
moment. It is a valid emergency action. But it does not represent root
cause. Adding `timeout=2` is the root cause fix — but even that is
incomplete without asking what the application *should* do when the
upstream is slow. A timeout without a strategy is a faster failure.
The real design conversation is:

| Option | Tradeoff |
|---|---|
| Timeout + return 503 | Fail fast and honest, but still a bad user experience |
| Timeout + retry with backoff | Adds resilience, but can amplify load on a struggling upstream |
| Timeout + circuit breaker | Stops calling a failing upstream until it recovers |
| Timeout + fallback response | Degrades gracefully with cached or partial data |

Asking *"what did we assume would never happen, and was that the right
assumption?"* is just as important as finding the smoking gun.
This scenario uses real tools against a realistic failure mode and
forces that conversation.

---

## The Problem

The Flask API exposes a `/data` endpoint that calls a slow internal
upstream (`/slow`) with no timeout configured. The application is served
by **Gunicorn** with a fixed thread pool of 10 threads (`--workers 1
--threads 10`). Flask defines the routes and application logic —
Gunicorn is the server that enforces the hard thread ceiling that makes
exhaustion possible.

Under concurrent load the thread pool fills entirely with threads blocked
on `recv()` waiting for a response that never returns in time. Once the
pool is exhausted, every new inbound request is immediately rejected with
a 503.

The service appears up — the process is running, the port is listening —
but it cannot serve any traffic. A standard health check against `/health`
still returns 200, which means alerting and orchestration systems
(e.g., Kubernetes liveness probes) will not detect the failure or
attempt a restart.

---

## Business Impact

| Metric          | Healthy baseline | During exhaustion |
|-----------------|-----------------|-------------------|
| p50 latency     | ~12 ms          | 8000 ms+          |
| p99 latency     | ~15 ms          | never resolves    |
| Error rate      | 0%              | 100%              |
| Health check    | passing         | passing (misleading) |

Every client request fails. Downstream services depending on this API
will cascade. Because the health check passes, automated recovery does
not trigger — the outage persists until a human intervenes or the
service is manually restarted (which only buys minutes before exhaustion
recurs).

---

## Root Cause

```python
# /data route — BUGGY
response = requests.get("http://localhost:5000/slow")  # no timeout
```

The missing `timeout` parameter means each thread will block on
`recv()` indefinitely. The `/slow` endpoint sleeps for 10 seconds,
so each call ties up a thread for at least that long. Because `/data`
calls `/slow` on the same Flask process, threads are consumed on both
sides of the call simultaneously — halving the effective pool capacity.

Gunicorn enforces a hard ceiling of 10 threads (`--threads 10`). With
`/data` and `/slow` each consuming a thread per request, the pool
exhausts at 5 concurrent requests. With 20 load-gen workers firing
simultaneously the pool is overwhelmed almost immediately.

---

## Methodology

### 1. Reproduce
Run `repro_issue.sh`. This starts the environment, captures a clean
baseline from `/stats`, then starts the load generator. After 20
seconds the stats endpoint becomes unresponsive — confirming exhaustion.

### 2. Isolate — process level
Find the gunicorn processes with `ps -ef | grep gunicorn`. Two processes
appear — the master (PID 1 in the container) and the worker. The worker
is the one with the most threads. Check thread count with `ps -eLf` and
open file descriptor count via `/proc/<pid>/fd`. Both climb under load
and plateau — confirming resource exhaustion, not a crash.

### 3. Isolate — syscall level (strace)
Attach strace to the **worker** PID with follow-forks enabled. The master
process manages workers and shows nothing useful — strace must target the
worker to see the blocked threads:

```bash
strace -p <worker_pid> -e trace=network -f 2>&1 | tee artifacts/evidence.log
```

The output immediately shows every worker thread blocked on `recvfrom()`
with no return — `<unfinished ...>` against every thread ID simultaneously.
Meanwhile the main thread continues calling `accept4()` successfully,
accepting new connections that have no thread available to serve them.
This is the smoking gun:

```
strace: Process 7 attached with 11 threads
[pid 24] recvfrom(34,  <unfinished ...>
[pid 23] recvfrom(25,  <unfinished ...>
[pid 22] recvfrom(26,  <unfinished ...>
...
[pid  7] accept4(3, {sa_family=AF_INET ...172.20.0.20...}) = 298
```

The kernel is waiting for bytes from the upstream `/slow` connection
that will never arrive within an acceptable window.

### 4. Corroborate — connection state (ss)
```bash
ss -tip
```
Shows the network-layer confirmation. Two states dominate:

- **CLOSE-WAIT** — the client gave up and closed its side of the
  connection, but the gunicorn thread never closed its end because it is
  still blocked on `recvfrom()`. This is the most prevalent state and
  directly correlates with blocked threads.
- **ESTAB with Recv-Q > 0** — new requests have arrived and the TCP
  data is sitting in the kernel buffer unread, because no thread is
  free to call `recv()` on it.

### 5. Resolve
`resolve_issue.sh` follows a structured deployment workflow rather than
applying a hotfix directly to the running process. The five steps are:

**Step 1 — Update the code**
`app_fixed.py` contains the corrected version of the application with
`timeout=2` applied. A 2-second timeout is a reasonable upper bound for
this application — if the upstream cannot respond within that window it
is considered degraded and the thread should fail fast rather than hold.
The original buggy file is preserved as `app_buggy.py` inside the
container for reference and diff comparison.

**Step 2 — QA validation**
The load generator is stopped to create a clean test window. The
api-server is restarted with the patched code and 10 sequential requests
are sent to `/data`. Each request is expected to return within the
timeout window — a 503 with an upstream timeout error is the correct
QA result, confirming threads fail fast rather than block. If any
request hangs beyond the timeout window the script exits with a
failure and does not proceed to production deployment.

**Step 3 — Deploy to production**
Once QA passes, the fixed file is explicitly deployed to the production
container. This step is intentionally separated from QA to reflect that
a passing test gate is required before production promotion.

**Step 4 — Restart Flask**
The api-server is restarted cleanly and the healthcheck is polled until
the service reports healthy before proceeding.

**Step 5 — Re-run failure scenario and verify**
The load generator is restarted at full concurrency using the same 20
second window as the original reproduction. Stats, thread count, and
active connections are captured. A healthy result shows the stats
endpoint responding, thread count stable, and no accumulation of blocked
`ESTABLISHED` connections.

---

## File Structure

```
lab/
├── README.md
├── repro_issue.sh          ← induces the failure + captures evidence to artifacts/
├── resolve_issue.sh        ← 5-step fix workflow + confirms recovery to artifacts/
├── docker-compose.yml
├── api-server/
│   ├── Dockerfile
│   ├── app.py              ← buggy version (no timeout)
│   ├── app_fixed.py        ← production fix (timeout=2)
│   └── requirements.txt
├── load-gen/
│   ├── Dockerfile
│   ├── load_gen.py
│   └── requirements.txt
└── artifacts/              ← empty, populated at runtime
    ├── evidence.log        ← strace + ss + fd count at time of failure
    └── fix.log             ← 5-step resolution log with before/after stats
```

---

## Run Order

### Linux
```bash
bash repro_issue.sh       # break it and capture evidence -> artifacts/evidence.log
bash resolve_issue.sh     # fix it and confirm recovery  -> artifacts/fix.log
```

### Windows (PowerShell)
```powershell
powershell -ExecutionPolicy Bypass -File .\repro_issue.ps1
powershell -ExecutionPolicy Bypass -File .\resolve_issue.ps1
```

All evidence is written to `artifacts/` automatically.
