# repro_issue.ps1
# Run from the lab/ directory: powershell -ExecutionPolicy Bypass -File .\repro_issue.ps1

$ErrorActionPreference = "Stop"
$EVIDENCE = ".\artifacts\evidence.log"
New-Item -ItemType Directory -Force -Path ".\artifacts" | Out-Null
if (Test-Path $EVIDENCE) { Remove-Item $EVIDENCE }

function Log {
    param([string]$msg)
    Write-Host $msg
    Add-Content -Path $EVIDENCE -Value $msg
}

Log "=== REPRODUCTION STARTED $(Get-Date) ==="

# Start environment
Log ""
Log "--- Starting lab environment ---"
docker compose up -d --build

# Wait for healthy
Log ""
Log "--- Waiting for api-server to be healthy ---"
while ($true) {
    $health = docker inspect api-server --format="{{.State.Health.Status}}"
    if ($health -match "healthy") { break }
    Write-Host "waiting..."
    Start-Sleep -Seconds 2
}
Log "api-server healthy."

# Baseline stats
Log ""
Log "--- Baseline stats (before load) ---"
try {
    $baseline = Invoke-WebRequest -Uri "http://172.20.0.10:5000/stats" -TimeoutSec 5 -UseBasicParsing
    Log $baseline.Content
} catch {
    Log "Baseline stats unavailable"
}

# Start load generator
Log ""
Log "--- Starting load generator ---"
docker compose restart load-gen

Log "Waiting 20s for thread pool to exhaust..."
Start-Sleep -Seconds 20

# Confirm failure
Log ""
Log "--- Stats under load ---"
try {
    $stats = Invoke-WebRequest -Uri "http://172.20.0.10:5000/stats" -TimeoutSec 3 -UseBasicParsing
    Log $stats.Content
} catch {
    Log "STATS ENDPOINT UNRESPONSIVE - thread pool exhausted"
}


# ════════════════════════════════════════════════════════════════════════════
# DIAGNOSTIC SEQUENCE
# Order: confirm process -> confirm socket -> inspect connections -> resource use
# ════════════════════════════════════════════════════════════════════════════

# Step 1: Is the process actually running?
# Before assuming anything is wrong at the network layer, verify the process
# exists. A missing process means a crash - a present one means it is alive
# but unable to serve, which leads us to look at connections next.
Log ""
Log "--- STEP 1: Is the process running? (ps -ef | grep gunicorn) ---"
Log "  Full output (all gunicorn entries):"
$psOutput = docker exec api-server ps -ef
$gunicornLines = $psOutput | Where-Object { $_ -match "gunicorn" -and $_ -notmatch "grep" }
$gunicornLines | ForEach-Object { Log "  $_" }
$FlaskLine = $gunicornLines | Select-Object -First 1
$FlaskPID = ($FlaskLine -replace '\s+', ' ').Trim().Split(' ')[1]
Log "  >> Gunicorn master PID: $FlaskPID"


# Step 2: Is the socket open and listening?
# Confirms the process has bound to its port. A LISTEN entry means requests
# CAN reach the app - so the failure is inside the app, not at the network layer.
Log ""
Log "--- STEP 2: Is the socket open and listening? (ss -tlnp | grep 5000) ---"
Log "  Command: ss -tlnp | grep 5000"
$listening = docker exec api-server sh -c "ss -tlnp | grep 5000"
if ($listening) {
    Log $listening
} else {
    Log "  WARNING: Nothing listening on 5000"
}


# Step 3: What is the state of active connections?
# CLOSE-WAIT means clients gave up but threads are still held.
# ESTAB with data in Recv-Q means new requests arrived but no thread is free.
Log ""
Log "--- STEP 3: Connection states - full picture (ss -tip) ---"
$ss = docker exec api-server ss -tip

Log "  Sample CLOSE-WAIT connections (clients gave up, threads still held):"
$cwLines = $ss | Where-Object { $_ -match "^CLOSE-WAIT" } | Select-Object -First 3
$cwLines | ForEach-Object { Log "  $_" }

Log "  Sample ESTAB connections with unread data in Recv-Q:"
$estabLines = $ss | Where-Object { $_ -match "^ESTAB" } | Select-Object -First 3
$estabLines | ForEach-Object { Log "  $_" }

$cwCount = ($ss | Where-Object { $_ -match "^CLOSE-WAIT" }).Count
$estabCount = ($ss | Where-Object { $_ -match "^ESTAB" }).Count
Log "  Connection state summary:"
Log "    CLOSE-WAIT count: $cwCount"
Log "    ESTAB count:      $estabCount"


# Step 4: Is there disk space? Could writes be failing?
# Rule out disk pressure before blaming threads or FDs.
Log ""
Log "--- STEP 4: Disk space check (df -h) ---"
Log "  Command: df -h (looking for partitions near 100% use)"
$df = docker exec api-server df -h
Log $df


# Step 5: Thread count - is the pool saturated?
# ps -eLf shows each thread as a separate line for the same PID.
# Sample lines show actual entries; wc -l gives the count at a glance.
Log ""
Log "--- STEP 5: Thread count - is the pool at its ceiling? ---"
Log "  Sample thread entries (ps -eLf | grep $FlaskPID):"
$threads = docker exec api-server sh -c "ps -eLf | grep $FlaskPID | grep -v grep"
$threads | Select-Object -First 3 | ForEach-Object { Log "  $_" }
$threadLines = $threads -split "`n" | Where-Object { $_.Trim() -ne "" }
$threadCount = $threadLines.Count
Log "  Short form (wc -l): Total threads for PID $FlaskPID = $threadCount"
Log "  >> Gunicorn configured with --threads 10. At or near 10 = pool saturated."


# Step 6: File descriptor count - are FDs accumulating?
# High FD count alongside CLOSE-WAIT confirms threads are holding sockets open.
Log ""
Log "--- STEP 6: File descriptor count (ls /proc/PID/fd) ---"
Log "  Sample FD entries (first 5):"
$fdSample = docker exec api-server sh -c "ls /proc/$FlaskPID/fd | head -5"
Log $fdSample
$fdCount = docker exec api-server sh -c "ls /proc/$FlaskPID/fd | wc -l"
Log "  Short form (wc -l): Open FDs for PID $FlaskPID = $fdCount"


# Step 7: strace - syscall-level proof
# recv() calls showing <unfinished ...> mean threads are blocked waiting for
# upstream bytes that will never arrive. This is the smoking gun.
Log ""
Log "--- STEP 7: strace - 30s capturing blocked syscalls (follow forks -f) ---"
Log "  Smoking gun: recv() lines showing <unfinished ...> across multiple thread IDs"

$straceCmd = "strace -p $FlaskPID -e trace=network -f 2>&1 & SPID=`$!; sleep 30; kill `$SPID 2>/dev/null; wait `$SPID 2>/dev/null; true"
$straceOut = docker exec api-server sh -c $straceCmd
Write-Host $straceOut
Add-Content -Path $EVIDENCE -Value $straceOut

Log ""
Log "=== REPRODUCTION COMPLETE $(Get-Date) ==="
Write-Host ""
Write-Host "Evidence saved to $EVIDENCE"
Write-Host "Smoking gun: Select-String 'unfinished' '$EVIDENCE'"
