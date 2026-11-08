#!/usr/bin/env python3
"""Подготовка HTTPS-целей из DOMAIN и начального файла метрик бэкапа."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


CHECKS = [
    ("portfolio", "", "/", "https_200"),
    ("www", "www", "/", "https_redirect"),
    ("bookreviews", "books", "/ready", "https_200"),
    ("foodgram", "foodgram", "/api/recipes/?limit=1", "https_200"),
    ("http-loadgen", "", "/loadgen/api/status", "https_200"),
    ("pvz-service", "pvz", "/health", "https_200"),
    ("billing", "pvz", "/billing/health", "https_200"),
]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--domain")
    args = parser.parse_args()
    app_dir = Path(__file__).resolve().parent
    domain = args.domain
    if domain is None:
        # Значения окружения Compose остаются в памяти. Выводим только публичный DOMAIN.
        config = json.loads(subprocess.check_output(
            ["docker", "compose", "--project-directory", str(app_dir), "config", "--format", "json"],
            text=True,
        ))
        domain = config["services"]["caddy"]["environment"]["DOMAIN"]
    domain = domain.strip().rstrip(".").encode("idna").decode("ascii").lower()
    label = r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"
    if len(domain) > 253 or not re.fullmatch(label + r"(?:\." + label + r")+", domain):
        parser.error("DOMAIN must be a DNS hostname")

    backups = app_dir / "backups"
    backups.mkdir(mode=0o700, exist_ok=True)
    backups.chmod(0o700)
    directory = backups / "monitoring"
    directory.mkdir(exist_ok=True)
    directory.chmod(0o755)
    targets = [
        {
            "targets": ["https://" + (subdomain + "." if subdomain else "") + domain + path],
            "labels": {"project": project, "module": module},
        }
        for project, subdomain, path, module in CHECKS
    ]
    with tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", dir=directory, prefix=".https-", suffix=".tmp", delete=False
    ) as output:
        temporary = Path(output.name)
        json.dump(targets, output, indent=2)
        output.write("\n")
    try:
        temporary.chmod(0o644)
        os.replace(temporary, directory / "https.json")
    finally:
        temporary.unlink(missing_ok=True)
    subprocess.run([sys.executable, str(app_dir / "backup-metrics.py"), "init"], check=True)
    print(f"Prepared {len(targets)} HTTPS targets for {domain}. Backup metric state ready.")


if __name__ == "__main__":
    main()
