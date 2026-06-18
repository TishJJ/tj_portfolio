import threading
import requests
import time

TARGET  = "http://172.20.0.10:5000"
WORKERS = 20


def hammer():
    while True:
        try:
            start = time.time()
            r     = requests.get(f"{TARGET}/data", timeout=30)
            elapsed = time.time() - start
            print(f"[{r.status_code}] {elapsed:.2f}s")
        except requests.exceptions.Timeout:
            print("[TIMEOUT] load-gen gave up after 30s")
        except Exception as e:
            print(f"[ERROR] {e}")


# Start worker threads
threads = []
for i in range(WORKERS):
    t = threading.Thread(target=hammer, daemon=True)
    t.start()
    threads.append(t)

print(f"Hammering {TARGET} with {WORKERS} workers...")

# Stats loop — runs independently of hammer threads
try:
    while True:
        time.sleep(5)
        try:
            r = requests.get(f"{TARGET}/stats", timeout=3)
            print(f"\n--- STATS ---\n{r.json()}\n")
        except Exception as e:
            print(f"\n--- STATS UNAVAILABLE: {e} ---\n")
except KeyboardInterrupt:
    print("Stopped.")
