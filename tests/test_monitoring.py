"""Регрессии публикации метрик и настоящего entrypoint бэкапа, без рабочих данных."""

import json
import os
from pathlib import Path
import runpy
import select
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import MagicMock, patch


DEPLOY = Path(__file__).resolve().parents[1] / "deploy"
PREFIX = "givemeanoffer_backup_"


class MonitoringTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.app = Path(self.temporary.name)
        for name in ["backup.sh", "backup-metrics.py", "monitoring-prepare.py"]:
            shutil.copyfile(DEPLOY / name, self.app / name)

    def metrics(self):
        lines = (self.app / "backups/metrics/backup.prom").read_text().splitlines()
        return {
            line.split()[0][len(PREFIX):]: int(line.split()[1])
            for line in lines if line.startswith(PREFIX)
        }

    def publish(self, event, timestamp, *args):
        script = self.app / "backup-metrics.py"
        with patch.object(sys, "argv", [str(script), event, *args]), patch("time.time", return_value=timestamp):
            runpy.run_path(str(script), run_name="__main__")

    def prepare(self, domain):
        return subprocess.run(
            [sys.executable, str(self.app / "monitoring-prepare.py"), "--domain", domain],
            capture_output=True, text=True,
        )

    def test_failure_preserves_last_success_and_init_preserves_state(self):
        self.publish("init", 100)
        self.assertEqual(set(self.metrics().values()), {0})
        self.publish("start", 100)
        self.assertEqual(self.metrics()["in_progress"], 1)
        self.publish("finish", 110, "--success", "1", "--duration", "10")
        path = self.app / "backups/metrics/backup.prom"
        successful = path.read_bytes()
        self.publish("init", 150)
        self.assertEqual(path.read_bytes(), successful)
        self.publish("start", 200)
        self.publish("finish", 207, "--success", "0", "--duration", "7")
        self.assertEqual(self.metrics(), {
            "last_attempt_timestamp_seconds": 200,
            "last_success_timestamp_seconds": 110,
            "last_run_success": 0,
            "last_run_duration_seconds": 7,
            "in_progress": 0,
        })
        self.assertEqual(list(path.parent.glob("*.tmp")), [])
        self.assertEqual(path.stat().st_mode & 0o777, 0o644)

    def test_targets_follow_domain_and_preserve_backup_result(self):
        self.publish("finish", 110, "--success", "1")
        result = self.prepare("Example.TEST.")
        self.assertEqual(result.returncode, 0, result.stderr)
        path = self.app / "backups/monitoring/https.json"
        targets = {item["labels"]["project"]: item for item in json.loads(path.read_text())}
        self.assertEqual(len(targets), 7)
        self.assertEqual(targets["bookreviews"]["targets"], ["https://books.example.test/ready"])
        self.assertEqual(targets["billing"]["targets"], ["https://pvz.example.test/billing/health"])
        self.assertEqual(targets["www"]["labels"]["module"], "https_redirect")
        self.assertEqual(self.metrics()["last_success_timestamp_seconds"], 110)
        previous = path.read_bytes()
        self.assertNotEqual(self.prepare("example.test/path").returncode, 0)
        self.assertEqual(path.read_bytes(), previous)
        self.assertEqual((self.app / "backups").stat().st_mode & 0o777, 0o700)
        self.assertEqual(path.stat().st_mode & 0o777, 0o644)

    def test_targets_read_compose_domain_without_printing_environment(self):
        env = self.prepare_backup()
        result = subprocess.run(
            [sys.executable, str(self.app / "monitoring-prepare.py")],
            env=env, capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("test-secret-value", result.stdout + result.stderr)
        path = self.app / "backups/monitoring/https.json"
        targets = json.loads(path.read_text())
        self.assertEqual(targets[0]["targets"], ["https://example.test/"])

    def prepare_backup(self):
        (self.app / ".env").write_text("RESTIC_REPOSITORY=s3:example.test/test\n")
        seed = self.app / "backups/foodgram-seed"
        seed.mkdir(parents=True)
        for name in ["foodgram.dump", "media.tar"]:
            (seed / name).write_bytes(b"synthetic seed")
        binary = self.app / "bin"
        binary.mkdir()
        docker = binary / "docker"
        docker.write_text("""#!/usr/bin/env python3
import os
import sys

args = sys.argv[1:]
if 'config' in args and args[0] == 'compose':
    print('{"services":{"caddy":{"environment":{"DOMAIN":"example.test","SECRET":"test-secret-value"}}}}')
elif 'pg_dump' in args:
    if os.environ.get('TEST_BACKUP_BLOCK'):
        print('DUMP_STARTED', file=sys.stderr, flush=True)
        sys.stdin.readline()
    if os.environ.get('TEST_BACKUP_FAILURE') == 'dump':
        sys.exit(17)
    print('synthetic dump')
elif 'alpine:3' in args:
    print('synthetic media')
elif 'restic/restic:0.19.1' in args:
    command = args[args.index('restic/restic:0.19.1') + 1]
    if os.environ.get('TEST_BACKUP_FAILURE') == command:
        sys.exit(23)
    if command == 'snapshots':
        print('[{"short_id":"example"}]')
    elif command == 'stats':
        print('Total Size: 42 B')
else:
    sys.exit('Unexpected docker invocation')
""")
        docker.chmod(0o755)
        return dict(os.environ, PATH=str(binary) + os.pathsep + os.environ["PATH"])

    def run_backup(self, env):
        return subprocess.run(
            ["bash", str(self.app / "backup.sh")], env=env,
            capture_output=True, text=True, timeout=20,
        )

    def test_backup_entrypoint_records_success_and_failures(self):
        env = self.prepare_backup()
        result = self.run_backup(env)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        last_success = self.metrics()["last_success_timestamp_seconds"]
        self.assertGreater(last_success, 0)
        self.assertEqual(self.metrics()["last_run_success"], 1)
        for failure, status in [("dump", 17), ("backup", 23), ("forget", 23)]:
            with self.subTest(failure=failure):
                result = self.run_backup(dict(env, TEST_BACKUP_FAILURE=failure))
                self.assertEqual(result.returncode, status, result.stdout + result.stderr)
                self.assertEqual(self.metrics()["last_success_timestamp_seconds"], last_success)
                self.assertEqual(self.metrics()["last_run_success"], 0)
                self.assertEqual(self.metrics()["in_progress"], 0)
        (self.app / ".env").unlink()
        result = self.run_backup(env)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.metrics()["last_success_timestamp_seconds"], last_success)
        self.assertEqual(self.metrics()["in_progress"], 0)

    def test_incomplete_external_backup_is_a_failure(self):
        env = self.prepare_backup()
        (self.app / ".env").write_text("")
        self.assertEqual(self.run_backup(env).returncode, 2)
        self.assertEqual(self.metrics()["last_run_success"], 0)
        self.assertEqual(self.metrics()["last_success_timestamp_seconds"], 0)
        (self.app / ".env").write_text("RESTIC_REPOSITORY=s3:example.test/test\n")
        (self.app / "backups/foodgram-seed/media.tar").unlink()
        self.assertEqual(self.run_backup(env).returncode, 1)
        self.assertEqual(self.metrics()["last_run_success"], 0)
        self.assertEqual(self.metrics()["in_progress"], 0)

    def test_concurrent_backup_cannot_replace_active_attempt(self):
        env = self.prepare_backup()
        first = subprocess.Popen(
            ["bash", str(self.app / "backup.sh")], env=dict(env, TEST_BACKUP_BLOCK="1"),
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        try:
            ready, _, _ = select.select([first.stderr], [], [], 10)
            self.assertTrue(ready, "First backup did not reach pg_dump")
            self.assertEqual(first.stderr.readline().strip(), "DUMP_STARTED")
            previous = self.metrics()
            self.assertEqual(previous["in_progress"], 1)
            second = self.run_backup(env)
            self.assertEqual(second.returncode, 1, second.stdout + second.stderr)
            self.assertEqual(self.metrics(), previous)
            stdout, stderr = first.communicate("continue\n", timeout=20)
            self.assertEqual(first.returncode, 0, stdout + stderr)
            self.assertEqual(self.metrics()["last_run_success"], 1)
            self.assertEqual(self.metrics()["in_progress"], 0)
        finally:
            if first.poll() is None:
                first.kill()
                first.communicate()


class DeploymentCheckTests(unittest.TestCase):
    def setUp(self):
        self.check = runpy.run_path(str(DEPLOY / "prometheus-check.py"))["check"]
        projects = self.check.__globals__["REQUIRED_PROJECTS"]
        self.probes = [{"metric": {"project": project}, "value": [0, "1"]} for project in projects]
        self.certificates = [
            {"metric": {"project": project}, "value": [0, str(time.time() + 86400)]}
            for project in projects
        ]
        self.overrides = {}
        jobs = ["prometheus", "pvz", "billing", "node-exporter", "blackbox-exporter", "https"]
        self.targets = [{"labels": {"job": job}, "health": "up"} for job in jobs]

    def api(self, base, path):
        if path == "targets":
            return {"activeTargets": self.targets}
        if path == "status/runtimeinfo":
            return {"reloadConfigSuccess": True}
        raise AssertionError(path)

    def query(self, base, expression):
        if expression in self.overrides:
            return self.overrides[expression]
        if expression.startswith("probe_success"):
            return self.probes
        if expression.startswith("probe_ssl_earliest_cert_expiry"):
            return self.certificates
        value = "0" if expression.startswith("node_textfile_scrape_error") else "1"
        return [{"metric": {}, "value": [0, value]}]

    def run_check(self):
        response = MagicMock()
        response.__enter__.return_value.status = 200
        with patch.dict(self.check.__globals__, {"api": self.api, "query": self.query}), patch(
            "urllib.request.urlopen", return_value=response,
        ), patch("builtins.print"):
            self.check("http://prometheus.test")

    def test_scrape_success_does_not_hide_failed_or_missing_https_probe(self):
        self.run_check()
        self.probes[0]["value"][1] = "0"
        with self.assertRaisesRegex(ValueError, "HTTPS or certificate check failed"):
            self.run_check()
        self.probes.pop(0)
        with self.assertRaisesRegex(ValueError, "Missing HTTPS probes"):
            self.run_check()

    def test_expired_certificate_and_exporter_errors_fail_deployment(self):
        self.certificates[0]["value"][1] = "1"
        with self.assertRaisesRegex(ValueError, "HTTPS or certificate check failed"):
            self.run_check()
        for expression, value in [
            ('node_textfile_scrape_error{job="node-exporter"}', "1"),
            ('node_scrape_collector_success{job="node-exporter"}', "0"),
            ('blackbox_exporter_config_last_reload_successful{job="blackbox-exporter"}', "0"),
        ]:
            with self.subTest(expression=expression):
                self.overrides = {expression: [{"metric": {}, "value": [0, value]}]}
                with self.assertRaisesRegex(ValueError, "Exporter check failed"):
                    self.run_check()


if __name__ == "__main__":
    unittest.main()
