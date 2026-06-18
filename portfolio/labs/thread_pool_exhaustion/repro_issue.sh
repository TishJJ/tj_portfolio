#!/bin/bash
set -e

EVIDENCE="./artifacts/evidence.log"
mkdir -p ./artifacts

echo "=== REPRODUCTION STARTED $(date) ===" | tee $EVIDENCE

# ── Start environment ─────────────────────────────────────────────────────────
echo -e "\n--- Starting lab environment ---" | tee -a $EVIDENCE
docker compose up -d --build

echo -e "\n--- Waiting for api-server to be healthy ---" | tee -a $EVIDENCE
until docker inspect api-server --format='{{.State.Health.Status}}' | grep -q "healthy"; do
    echo "waiting..."
    sleep 2
done
echo "api-server healthy." | tee -a $EVIDENCE

# ── Baseline ──────────────────────────────────────────────────────────────────
echo -e "\n--- Baseline stats (before load) ---" | tee -a $EVIDENCE
curl -s http://172.20.0.10:5000/stats | python3 -m json.tool | tee -a $EVIDENCE

# ── Induce failure ────────────────────────────────────────────────────────────
echo -e "\n--- Starting load generator ---" | tee -a $EVIDENCE
docker compose restart load-gen

echo "Waiting 20s for thread pool to exhaust..." | tee -a $EVIDENCE
sleep 20

# ── Confirm failure ───────────────────────────────────────────────────────────
echo -e "\n--- Stats under load ---" | tee -a $EVIDENCE
curl -s --max-time 3 http://172.20.0.10:5000/stats | python3 -m json.tool | tee -a $EVIDENCE \
    || echo "STATS ENDPOINT UNRESPONSIVE - thread pool exhausted" | tee -a $EVIDENCE


# ════════════════════════════════════════════════════════════════════════════
# DIAGNOSTIC SEQUENCE
# Order: confirm process → confirm socket → inspect connections → resource use
# ════════════════════════════════════════════════════════════════════════════

# Step 1: Is the process actually running?
# Before assuming anything is wrong at the network layer, verify the process
# exists. A missing process means a crash — a present one means it's alive
# but unable to serve, which leads us to look at connections next.
echo -e "\n--- STEP 1: Is the process running? (ps -ef | grep gunicorn) ---" | tee -a $EVIDENCE
echo "  Full output (all gunicorn entries):" | tee -a $EVIDENCE
docker exec api-server ps -ef | grep gunicorn | grep -v grep | tee -a $EVIDENCE
PID=$(docker exec api-server ps -ef | grep "gunicorn" | grep -v grep | awk '{print $2}' | head -1)
echo "  >> Gunicorn master PID: $PID" | tee -a $EVIDENCE


# Step 2: Is the socket open and listening?
# Confirms the process has bound to its port. If nothing is listening, the
# process died or never started. A LISTEN entry here means requests CAN reach
# the app — so the failure is inside the app, not at the network layer.
echo -e "\n--- STEP 2: Is the socket open and listening? (ss -tlnp) ---" | tee -a $EVIDENCE
echo "  Command: ss -tlnp | grep 5000" | tee -a $EVIDENCE
docker exec api-server ss -tlnp | grep 5000 | tee -a $EVIDENCE || echo "  WARNING: Nothing listening on 5000" | tee -a $EVIDENCE


# Step 3: What is the state of active connections?
# Now that we know the process is running and the port is open, we look at
# connection states. CLOSE-WAIT means clients gave up but threads are still
# held. ESTAB with data in Recv-Q means new requests arrived but no thread
# is free to read them. This is the network-layer smoking gun.
echo -e "\n--- STEP 3: Connection states - full picture (ss -tip) ---" | tee -a $EVIDENCE
echo "  Sample CLOSE-WAIT connections (clients gave up, threads still held):" | tee -a $EVIDENCE
docker exec api-server ss -tip | grep "CLOSE-WAIT" | head -3 | tee -a $EVIDENCE
echo "  Sample ESTAB connections with unread data in Recv-Q:" | tee -a $EVIDENCE
docker exec api-server ss -tip | grep "^ESTAB" | awk '$2 > 0' | head -3 | tee -a $EVIDENCE
echo "  Connection state summary:" | tee -a $EVIDENCE
echo "    CLOSE-WAIT count: $(docker exec api-server ss -tip | grep -c 'CLOSE-WAIT' || true)" | tee -a $EVIDENCE
echo "    ESTAB count:      $(docker exec api-server ss -tip | grep -c '^ESTAB' || true)" | tee -a $EVIDENCE


# Step 4: Is there disk space? Could writes be failing?
# Before blaming threads or FDs, rule out disk pressure. A full disk can
# cause silent failures that look like hangs. Cheap check, rules out a class
# of problems quickly.
echo -e "\n--- STEP 4: Disk space check (df -h) ---" | tee -a $EVIDENCE
echo "  Command: df -h (looking for partitions near 100% use)" | tee -a $EVIDENCE
docker exec api-server df -h | tee -a $EVIDENCE


# Step 5: Thread count — is the pool saturated?
# With disk ruled out, we look at thread exhaustion. ps -eLf shows each
# thread as a separate line for the same PID. Count confirms the pool ceiling
# has been hit. The short wc -l version gives the number; the sample lines
# show the actual thread entries so we can see they are all the same process.
echo -e "\n--- STEP 5: Thread count — is the pool at its ceiling? ---" | tee -a $EVIDENCE
echo "  Sample thread entries (ps -eLf | grep $PID):" | tee -a $EVIDENCE
docker exec api-server ps -eLf | grep $PID | grep -v grep | head -3 | tee -a $EVIDENCE
THREAD_COUNT=$(docker exec api-server ps -eLf | grep $PID | grep -v grep | wc -l)
echo "  Short form (wc -l): Total threads for PID $PID = $THREAD_COUNT" | tee -a $EVIDENCE
echo "  >> Gunicorn configured with --threads 10. At or near 10 = pool saturated." | tee -a $EVIDENCE


# Step 6: File descriptor count — are FDs accumulating?
# FDs climb when connections open faster than they close. A high FD count
# alongside CLOSE-WAIT confirms threads are holding sockets open. The sample
# lines show actual FD entries; wc -l gives the total at a glance.
echo -e "\n--- STEP 6: File descriptor count (ls /proc/PID/fd) ---" | tee -a $EVIDENCE
echo "  Sample FD entries (ls /proc/$PID/fd | head -5):" | tee -a $EVIDENCE
docker exec api-server ls /proc/$PID/fd | head -5 | tee -a $EVIDENCE
FD_COUNT=$(docker exec api-server ls /proc/$PID/fd | wc -l)
echo "  Short form (wc -l): Open FDs for PID $PID = $FD_COUNT" | tee -a $EVIDENCE


# Step 7: strace — syscall-level proof
# ss and ps told us what is happening externally. strace tells us exactly
# what the kernel is doing on behalf of each thread. recv() calls showing
# <unfinished ...> mean threads are blocked waiting for upstream bytes that
# will never arrive within an acceptable window. This is the smoking gun.
echo -e "\n--- STEP 7: strace - 30s capturing blocked syscalls (follow forks -f) ---" | tee -a $EVIDENCE
echo "  Smoking gun: recv() lines showing <unfinished ...> across multiple thread IDs" | tee -a $EVIDENCE
docker exec api-server sh -c "strace -p $PID -e trace=network -f 2>&1 & SPID=\$!; sleep 30; kill \$SPID 2>/dev/null; wait \$SPID 2>/dev/null; true" | tee -a $EVIDENCE


echo -e "\n=== REPRODUCTION COMPLETE $(date) ===" | tee -a $EVIDENCE
echo ""
echo "Evidence saved to $EVIDENCE"
echo "Smoking gun: grep 'unfinished' $EVIDENCE"
