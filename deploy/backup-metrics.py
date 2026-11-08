#!/usr/bin/env python3
"""Атомарная публикация результата backup.sh для textfile-коллектора."""

import argparse
import os
from pathlib import Path
import tempfile
import time


PREFIX = "givemeanoffer_backup_"
METRICS = {
    "last_attempt_timestamp_seconds": "Start time of the latest backup attempt.",
    "last_success_timestamp_seconds": "Completion time of the latest fully successful backup.",
    "last_run_success": "Whether the latest completed backup succeeded.",
    "last_run_duration_seconds": "Duration of the latest completed backup.",
    "in_progress": "Whether a started backup has not reported completion.",
}


def read_values(path):
    values = dict.fromkeys(METRICS, 0)
    if path.exists():
        for line in path.read_text(encoding="utf-8").splitlines():
            fields = line.split()
            if len(fields) != 2 or not fields[0].startswith(PREFIX):
                continue
            name = fields[0][len(PREFIX):]
            if name in values:
                try:
                    value = int(fields[1])
                    if value < 0:
                        raise ValueError
                except ValueError:
                    raise ValueError("Invalid backup metric " + name) from None
                values[name] = value
    return values


def publish(path, values, initialize):
    with tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", dir=path.parent, prefix=".backup-", suffix=".tmp", delete=False
    ) as output:
        temporary = Path(output.name)
        for name, description in METRICS.items():
            full_name = PREFIX + name
            output.write(f"# HELP {full_name} {description}\n")
            output.write(f"# TYPE {full_name} gauge\n")
            output.write(f"{full_name} {values[name]}\n")
    try:
        temporary.chmod(0o644)
        if initialize:
            # Другой запуск мог опубликовать результат после проверки существования файла.
            try:
                os.link(temporary, path)
            except FileExistsError:
                pass
        else:
            os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("event", choices=["init", "start", "finish"])
    parser.add_argument("--directory", type=Path, default=Path(__file__).resolve().parent / "backups/metrics")
    parser.add_argument("--success", type=int, choices=[0, 1])
    parser.add_argument("--duration", type=int, default=0)
    args = parser.parse_args()
    if args.event == "finish" and args.success is None:
        parser.error("finish requires --success")
    if args.duration < 0:
        parser.error("--duration must be nonnegative")

    args.directory.mkdir(parents=True, exist_ok=True)
    args.directory.chmod(0o755)
    path = args.directory / "backup.prom"
    values = read_values(path)
    if args.event == "start":
        values["last_attempt_timestamp_seconds"] = int(time.time())
        values["in_progress"] = 1
    elif args.event == "finish":
        values["last_run_success"] = args.success
        values["last_run_duration_seconds"] = args.duration
        values["in_progress"] = 0
        if args.success:
            values["last_success_timestamp_seconds"] = int(time.time())
    publish(path, values, initialize=args.event == "init")


if __name__ == "__main__":
    main()
