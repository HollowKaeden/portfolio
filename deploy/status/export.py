#!/usr/bin/env python3
"""Публикует сводку по HTTPS-проверкам из уже сохранённых метрик Prometheus."""

import argparse
from collections import defaultdict
import json
import math
import os
from pathlib import Path
import sys
import tempfile
import time
from urllib.parse import urlencode
from urllib.request import urlopen


PROJECTS = ("portfolio", "bookreviews", "foodgram", "pvz-service", "http-loadgen")
PERIOD = 24 * 3600
BUCKET = 15 * 60
INTERVAL = 60
QUERY = (
    '{job="https",__name__=~"probe_success|probe_duration_seconds",'
    f'project=~"{"|".join(PROJECTS)}"}}[24h]'
)


def snapshot(series, now):
    # Both metrics carry the same timestamp when taken from a single probe.
    checks = defaultdict(dict)
    durations = {}
    start = now - PERIOD
    for result in series:
        labels = result["metric"]
        project = labels.get("project")
        metric = labels.get("__name__")
        if project not in PROJECTS or metric not in ("probe_success", "probe_duration_seconds"):
            continue
        instance = labels.get("instance")
        for timestamp, raw in result["values"]:
            if not start <= timestamp <= now:
                continue
            value = float(raw)
            key = (instance, timestamp)
            if metric == "probe_success" and value in (0, 1):
                checks[project][key] = bool(value)
            elif metric == "probe_duration_seconds" and math.isfinite(value) and value >= 0:
                durations[project, key] = value * 1000

    projects = {}
    for project in PROJECTS:
        samples = checks[project]
        latest = max(samples, key=lambda key: key[1], default=None)
        available = samples.get(latest)
        buckets = [[] for _ in range(PERIOD // BUCKET)]
        for key, success in samples.items():
            duration = durations.get((project, key))
            if success and duration is not None:
                index = min(len(buckets) - 1, int((key[1] - start) // BUCKET))
                buckets[index].append(duration)
        duration = durations.get((project, latest)) if available else None
        projects[project] = {
            "checked_at": latest[1] if latest else None,
            "available": available,
            "duration_ms": round(duration) if duration is not None else None,
            "history_ms": [round(sum(bucket) / len(bucket)) if bucket else None for bucket in buckets],
        }
    return {"generated_at": now, "projects": projects}


def publish(path, data):
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent, delete=False) as output:
        temporary = Path(output.name)
    try:
        with temporary.open("w", encoding="utf-8") as output:
            json.dump(data, output, separators=(",", ":"), allow_nan=False)
            output.write("\n")
        temporary.chmod(0o644)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def export(prometheus, output):
    now = int(time.time())
    query = urlencode({"query": QUERY, "time": now, "timeout": "5s"})
    with urlopen(f"{prometheus}/api/v1/query?{query}", timeout=8) as response:
        data = json.load(response)
    if data["status"] != "success" or data["data"]["resultType"] != "matrix":
        raise ValueError("Неожиданный ответ Prometheus")
    publish(output, snapshot(data["data"]["result"], now))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prometheus", default="http://prometheus:9090")
    parser.add_argument("--output", type=Path, default=Path("/data/data.json"))
    parser.add_argument("--once", action="store_true")
    args = parser.parse_args()
    while True:
        started = time.monotonic()
        try:
            export(args.prometheus, args.output)
        except (OSError, ValueError, KeyError, TypeError) as error:
            print(f"Не удалось обновить страницу статуса: {error}", file=sys.stderr)
            if args.once:
                return 1
        if args.once:
            return 0
        time.sleep(max(1, INTERVAL - (time.monotonic() - started)))


if __name__ == "__main__":
    sys.exit(main())
