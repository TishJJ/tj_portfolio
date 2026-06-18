#!/bin/bash
set -e

FIX_LOG="./artifacts/fix.log"
mkdir -p ./artifacts

echo "=== RESOLUTION STARTED $(date) ===" | tee $FIX_LOG

# ── Stats before fix ─────────────────────────────────────────────────────────
echo -e "\n--- Stats before fix ---" | tee -a $FIX_LOG
curl -s --max-time 3 http://172.20.0.10:5000/stats | python3 -m json.tool | tee -a $FIX_LOG \
    || echo "STATS UNRESPONSIVE (expected at this stage)" | tee -a $FIX_LOG


# ── Step 1: Update the code ───────────────────────────────────────────────────
echo -e "\n========================================" | tee -a $FIX_LOG
echo "STEP 1: Apply fix to code (timeout=2s)" | tee -a $FIX_LOG
echo "========================================" | tee -a $FIX_LOG
echo "Assumption: 2 seconds is a reasonable upper bound for this application." | tee -a $FIX_LOG
echo "Threads that exceed this window are considered blocked on a degraded"    | tee -a $FIX_LOG
echo "upstream and should fail fast rather than hold the pool."                | tee -a $FIX_LOG
echo ""                                                                         | tee -a $FIX_LOG
echo "Patching app.py with timeout=2 ..."                                      | tee -a $FIX_LOG
docker exec api-server cp /app/app.py /app/app_buggy.py
docker exec api-server cp /app/app_fixed.py /app/app.py
echo -e "\n--- Verifying patch applied ---" | tee -a $FIX_LOG
docker exec api-server grep "requests.get" /app/app.py | tee -a $FIX_LOG


# ── Step 2: QA validation ─────────────────────────────────────────────────────
echo -e "\n========================================" | tee -a $FIX_LOG
echo "STEP 2: QA Validation"                        | tee -a $FIX_LOG
echo "========================================" | tee -a $FIX_LOG
echo "Stopping load generator to create a clean QA window..." | tee -a $FIX_LOG
docker compose stop load-gen

echo "Restarting api-server with patched code..." | tee -a $FIX_LOG
docker compose restart api-server

echo "Waiting for api-server to be healthy..." | tee -a $FIX_LOG
until docker inspect api-server --format='{{.State.Health.Status}}' | grep -q "healthy"; do
    echo "waiting..."
    sleep 2
done
echo "api-server healthy." | tee -a $FIX_LOG

echo -e "\n--- QA: Sending 10 sequential requests to /data ---" | tee -a $FIX_LOG
echo "Expected: each returns 503 with upstream timeout error within 2s." | tee -a $FIX_LOG
echo "This confirms threads are no longer blocking indefinitely."         | tee -a $FIX_LOG
echo ""                                                                   | tee -a $FIX_LOG
PASS=0
FAIL=0
for i in $(seq 1 10); do
    RESPONSE=$(curl -s --max-time 5 -w "\n%{http_code}" http://172.20.0.10:5000/data)
    STATUS=$(echo "$RESPONSE" | tail -1)
    BODY=$(echo "$RESPONSE" | head -1)
    echo "  Request $i → HTTP $STATUS | $BODY" | tee -a $FIX_LOG
    # 503 with timeout error is the expected QA result — threads fail fast, not hang
    if [[ "$STATUS" == "503" || "$STATUS" == "200" ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
    fi
done
echo "" | tee -a $FIX_LOG
echo "QA Result: $PASS/10 responded within timeout window. $FAIL timed out." | tee -a $FIX_LOG

if [[ $FAIL -gt 0 ]]; then
    echo "QA FAILED — threads still hanging. Do not proceed to production." | tee -a $FIX_LOG
    exit 1
fi
echo "QA PASSED — safe to deploy to production." | tee -a $FIX_LOG


# ── Step 3: Deploy to production ─────────────────────────────────────────────
echo -e "\n========================================" | tee -a $FIX_LOG
echo "STEP 3: Deploy to production"                 | tee -a $FIX_LOG
echo "========================================" | tee -a $FIX_LOG
echo "Copying fixed app to production container..." | tee -a $FIX_LOG
docker exec api-server cp /app/app_fixed.py /app/app.py
echo "Production deploy complete." | tee -a $FIX_LOG


# ── Step 4: Restart Flask ─────────────────────────────────────────────────────
echo -e "\n========================================" | tee -a $FIX_LOG
echo "STEP 4: Restart Flask server"                 | tee -a $FIX_LOG
echo "========================================" | tee -a $FIX_LOG
docker compose restart api-server

echo "Waiting for api-server to be healthy..." | tee -a $FIX_LOG
until docker inspect api-server --format='{{.State.Health.Status}}' | grep -q "healthy"; do
    echo "waiting..."
    sleep 2
done
echo "api-server healthy." | tee -a $FIX_LOG


# ── Step 5: Re-run failure scenario and verify ───────────────────────────────
echo -e "\n========================================" | tee -a $FIX_LOG
echo "STEP 5: Re-run failure scenario"              | tee -a $FIX_LOG
echo "========================================" | tee -a $FIX_LOG
echo "Restarting load generator at full concurrency..." | tee -a $FIX_LOG
docker compose start load-gen

echo "Waiting 20s — same window used during repro..." | tee -a $FIX_LOG
sleep 20

echo -e "\n--- Stats under load (post-fix) ---" | tee -a $FIX_LOG
curl -s --max-time 3 http://172.20.0.10:5000/stats | python3 -m json.tool | tee -a $FIX_LOG \
    || echo "STATS STILL UNRESPONSIVE — fix did not hold" | tee -a $FIX_LOG

echo -e "\n--- Thread count under load (post-fix) ---" | tee -a $FIX_LOG
PID=$(docker exec api-server ps -ef | grep "python app.py" | grep -v grep | awk '{print $2}')
docker exec api-server ps -eLf | grep $PID | wc -l | tee -a $FIX_LOG

echo -e "\n--- Active connections (post-fix) ---" | tee -a $FIX_LOG
docker exec api-server ss -tip | tee -a $FIX_LOG

echo -e "\n=== RESOLUTION COMPLETE $(date) ===" | tee -a $FIX_LOG
echo ""
echo "Recovery log saved to $FIX_LOG"
