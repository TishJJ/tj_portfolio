# resolve_issue.ps1
# Run from the lab/ directory: powershell -ExecutionPolicy Bypass -File .\resolve_issue.ps1

$ErrorActionPreference = "Stop"
$FIX_LOG = ".\artifacts\fix.log"
New-Item -ItemType Directory -Force -Path ".\artifacts" | Out-Null
if (Test-Path $FIX_LOG) { Remove-Item $FIX_LOG }

function Log {
    param([string]$msg)
    Write-Host $msg
    Add-Content -Path $FIX_LOG -Value $msg
}

function WaitForHealthy {
    Log "Waiting for api-server to be healthy..."
    while ($true) {
        $health = docker inspect api-server --format="{{.State.Health.Status}}"
        if ($health -match "healthy") { break }
        Write-Host "waiting..."
        Start-Sleep -Seconds 2
    }
    Log "api-server healthy."
}

Log "=== RESOLUTION STARTED $(Get-Date) ==="

# Stats before fix
Log ""
Log "--- Stats before fix ---"
try {
    $stats = Invoke-WebRequest -Uri "http://172.20.0.10:5000/stats" -TimeoutSec 3 -UseBasicParsing
    Log $stats.Content
} catch {
    Log "STATS UNRESPONSIVE (expected at this stage)"
}

# Step 1: Apply fix
Log ""
Log "========================================"
Log "STEP 1: Apply fix to code (timeout=2s)"
Log "========================================"
Log "Assumption: 2 seconds is a reasonable upper bound for this application."
Log "Threads that exceed this window fail fast rather than hold the pool."
Log ""
Log "Patching app.py with timeout=2 ..."
docker exec api-server cp /app/app.py /app/app_buggy.py
docker exec api-server cp /app/app_fixed.py /app/app.py

Log ""
Log "--- Verifying patch applied ---"
$patch = docker exec api-server grep "requests.get" /app/app.py
Log $patch

# Step 2: QA validation
Log ""
Log "========================================"
Log "STEP 2: QA Validation"
Log "========================================"
Log "Stopping load generator to create a clean QA window..."
docker compose stop load-gen

Log "Restarting api-server with patched code..."
docker compose restart api-server
WaitForHealthy

Log ""
Log "--- QA: Sending 10 sequential requests to /data ---"
Log "Expected: each returns within 2s. 503 with timeout error is correct QA result."
Log ""

$pass = 0
$fail = 0

for ($i = 1; $i -le 10; $i++) {
    try {
        $r = Invoke-WebRequest -Uri "http://172.20.0.10:5000/data" -TimeoutSec 5 -UseBasicParsing
        Log "  Request $i - HTTP $($r.StatusCode) | $($r.Content)"
        $pass++
    } catch {
        $code = $_.Exception.Response.StatusCode.value__
        if ($code -eq 503) {
            Log "  Request $i - HTTP 503 (upstream timeout - expected)"
            $pass++
        } else {
            Log "  Request $i - HUNG or unexpected error: $_"
            $fail++
        }
    }
}

Log ""
Log "QA Result: $pass/10 responded within timeout window. $fail timed out."

if ($fail -gt 0) {
    Log "QA FAILED - threads still hanging. Do not proceed to production."
    exit 1
}
Log "QA PASSED - safe to deploy to production."

# Step 3: Deploy to production
Log ""
Log "========================================"
Log "STEP 3: Deploy to production"
Log "========================================"
Log "Copying fixed app to production container..."
docker exec api-server cp /app/app_fixed.py /app/app.py
Log "Production deploy complete."

# Step 4: Restart Flask
Log ""
Log "========================================"
Log "STEP 4: Restart Flask server"
Log "========================================"
docker compose restart api-server
WaitForHealthy

# Step 5: Re-run failure scenario and verify
Log ""
Log "========================================"
Log "STEP 5: Re-run failure scenario"
Log "========================================"
Log "Restarting load generator at full concurrency..."
docker compose start load-gen

Log "Waiting 20s - same window used during repro..."
Start-Sleep -Seconds 20

Log ""
Log "--- Stats under load (post-fix) ---"
try {
    $stats = Invoke-WebRequest -Uri "http://172.20.0.10:5000/stats" -TimeoutSec 3 -UseBasicParsing
    Log $stats.Content
} catch {
    Log "STATS STILL UNRESPONSIVE - fix did not hold"
}

Log ""
Log "--- Thread count under load (post-fix) ---"
$psOutput = docker exec api-server ps -ef
$FlaskLine = $psOutput | Where-Object { $_ -match "python|gunicorn" -and $_ -notmatch "grep" } | Select-Object -First 1
$FlaskPID = ($FlaskLine -replace '\s+', ' ').Trim().Split(' ')[1]
$threadCount = docker exec api-server sh -c "ps -eLf | grep $FlaskPID | wc -l"
Log "Thread count: $threadCount"

Log ""
Log "--- Active connections (post-fix) ---"
$ss = docker exec api-server ss -tip
Log $ss

Log ""
Log "=== RESOLUTION COMPLETE $(Get-Date) ==="
Write-Host ""
Write-Host "Recovery log saved to $FIX_LOG"
