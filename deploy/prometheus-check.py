#!/usr/bin/env python3
"""Проверка готовности, конфигурации и реального сбора метрик после деплоя."""

import argparse
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


def api(base, path):
    with urllib.request.urlopen(base + "/api/v1/" + path, timeout=5) as response:
        result = json.load(response)
    if result.get("status") != "success":
        raise ValueError(result.get("error", "Prometheus API error"))
    return result["data"]


def check(base):
    with urllib.request.urlopen(base + "/-/ready", timeout=5) as response:
        if response.status != 200:
            raise ValueError("Prometheus is not ready")

    targets = api(base, "targets")["activeTargets"]
    jobs = {target["labels"].get("job") for target in targets}
    missing = {"prometheus", "pvz", "billing"} - jobs
    if missing:
        raise ValueError("Missing targets: " + ", ".join(sorted(missing)))
    failed = [
        target["labels"].get("job", "unknown") + ": " + target["health"]
        + " " + target.get("lastError", "")
        for target in targets if target["health"] != "up"
    ]
    if failed:
        raise ValueError("Targets not up: " + "; ".join(failed))

    # runtimeinfo отражает результат reload сразу, без ожидания следующего self-scrape.
    if not api(base, "status/runtimeinfo")["reloadConfigSuccess"]:
        raise ValueError("Configuration reload failed")

    for expression in [
        'pvz_outbox_pending{job="pvz"}',
        'billing_dlq_size{job="billing"}',
    ]:
        data = api(base, "query?" + urllib.parse.urlencode({"query": expression}))
        if data["resultType"] != "vector" or not data["result"]:
            raise ValueError("No samples for " + expression)

    print(f"Prometheus OK: {len(targets)} targets up, reload successful, pvz/billing samples present")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default="http://127.0.0.1:9090")
    parser.add_argument("--timeout", type=float, default=120)
    args = parser.parse_args()
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    deadline = time.monotonic() + args.timeout
    previous = None
    while True:
        try:
            check(args.url.rstrip("/"))
            return 0
        except (urllib.error.URLError, OSError, ValueError, KeyError) as error:
            message = str(error)
            if message != previous:
                print("Waiting for Prometheus: " + message, flush=True)
                previous = message
            if time.monotonic() >= deadline:
                print("Prometheus check failed: " + message, file=sys.stderr)
                return 1
            time.sleep(min(5, max(0, deadline - time.monotonic())))


if __name__ == "__main__":
    sys.exit(main())
