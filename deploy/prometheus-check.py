#!/usr/bin/env python3
"""Проверка готовности, конфигурации и реального сбора метрик после деплоя."""

import argparse
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


REQUIRED_PROJECTS = {
    "portfolio", "www", "bookreviews", "foodgram", "http-loadgen", "pvz-service", "billing",
}


def api(base, path):
    with urllib.request.urlopen(base + "/api/v1/" + path, timeout=5) as response:
        result = json.load(response)
    if result.get("status") != "success":
        raise ValueError(result.get("error", "Prometheus API error"))
    return result["data"]


def query(base, expression):
    data = api(base, "query?" + urllib.parse.urlencode({"query": expression}))
    if data["resultType"] != "vector" or not data["result"]:
        raise ValueError("No samples for " + expression)
    return data["result"]


def check(base):
    with urllib.request.urlopen(base + "/-/ready", timeout=5) as response:
        if response.status != 200:
            raise ValueError("Prometheus is not ready")

    targets = api(base, "targets")["activeTargets"]
    jobs = {target["labels"].get("job") for target in targets}
    missing = {"prometheus", "pvz", "billing", "node-exporter", "blackbox-exporter", "https"} - jobs
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
        'node_cpu_seconds_total{job="node-exporter"}',
        'node_memory_MemAvailable_bytes{job="node-exporter"}',
        'node_filesystem_avail_bytes{job="node-exporter",mountpoint="/"}',
        'givemeanoffer_backup_last_success_timestamp_seconds{job="node-exporter"}',
        'givemeanoffer_backup_last_attempt_timestamp_seconds{job="node-exporter"}',
        'givemeanoffer_backup_last_run_success{job="node-exporter"}',
        'givemeanoffer_backup_last_run_duration_seconds{job="node-exporter"}',
        'givemeanoffer_backup_in_progress{job="node-exporter"}',
    ]:
        query(base, expression)

    for expression, expected in [
        ('node_textfile_scrape_error{job="node-exporter"}', 0),
        ('node_scrape_collector_success{job="node-exporter"}', 1),
        ('blackbox_exporter_config_last_reload_successful{job="blackbox-exporter"}', 1),
    ]:
        if any(float(sample["value"][1]) != expected for sample in query(base, expression)):
            raise ValueError("Exporter check failed for " + expression)

    for metric, threshold in [("probe_success", 1), ("probe_ssl_earliest_cert_expiry", time.time())]:
        results = query(base, metric + '{job="https"}')
        projects = {sample["metric"].get("project") for sample in results}
        missing = REQUIRED_PROJECTS - projects
        if missing:
            raise ValueError("Missing HTTPS probes for " + ", ".join(sorted(missing)))
        failed = [sample["metric"]["project"] for sample in results if float(sample["value"][1]) < threshold]
        if failed:
            raise ValueError("HTTPS or certificate check failed for " + ", ".join(sorted(failed)))

    print(f"Prometheus OK. All {len(targets)} targets up. App, host, HTTPS and backup metrics present.")


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
