from flask import Flask, jsonify
import requests
import threading
import time
import statistics

app = Flask(__name__)

# Stats tracking
stats = {
    "requests": 0,
    "timeouts": 0,
    "errors": 0,
    "latencies": []
}
stats_lock = threading.Lock()


@app.route("/health")
def health():
    return jsonify({"status": "ok"})


@app.route("/slow")
def slow():
    time.sleep(10)
    return jsonify({"data": "finally done"})


@app.route("/data")
def data():
    start = time.time()
    try:
        # FIX: timeout=2 — threads fail fast and free up for the next request.
        # A 2 second timeout is a reasonable upper bound for this application.
        # If the upstream cannot respond in 2 seconds it is considered degraded
        # and we return a clean 503 rather than holding the thread indefinitely.
        response = requests.get("http://localhost:5000/slow", timeout=2)
        elapsed = time.time() - start
        with stats_lock:
            stats["requests"] += 1
            stats["latencies"].append(elapsed)
        return jsonify({"result": response.json()})
    except requests.exceptions.Timeout:
        with stats_lock:
            stats["timeouts"] += 1
        return jsonify({"error": "upstream timeout"}), 503
    except Exception as e:
        with stats_lock:
            stats["errors"] += 1
        return jsonify({"error": str(e)}), 503


@app.route("/stats")
def get_stats():
    with stats_lock:
        latencies = stats["latencies"][-100:]
        p50 = round(statistics.median(latencies) * 1000) if latencies else 0
        p99 = round(sorted(latencies)[int(len(latencies) * 0.99)] * 1000) if len(latencies) > 10 else 0
        return jsonify({
            "requests":  stats["requests"],
            "timeouts":  stats["timeouts"],
            "errors":    stats["errors"],
            "p50_ms":    p50,
            "p99_ms":    p99
        })
