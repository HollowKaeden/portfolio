import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "deploy" / "status" / "export.py"
SPEC = importlib.util.spec_from_file_location("status_export", SCRIPT)
status_export = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(status_export)


def series(name, values, project="bookreviews", instance="https://books.example.invalid/ready"):
    return {"metric": {"__name__": name, "project": project, "instance": instance}, "values": values}


class StatusExportTests(unittest.TestCase):
    def test_averages_successful_checks_in_buckets_and_preserves_gaps(self):
        now = 200_000
        data = status_export.snapshot([
            series("probe_success", [(now - 920, "1"), (now - 910, "1"), (now - 900, "0"), (now, "0")]),
            series("probe_duration_seconds", [(now - 920, "0.1"), (now - 910, "0.3"), (now - 900, "5"), (now, "5")]),
        ], now)
        check = data["projects"]["bookreviews"]
        self.assertFalse(check["available"])
        self.assertEqual(check["checked_at"], now)
        self.assertIsNone(check["duration_ms"])
        self.assertEqual(len(check["history_ms"]), 96)
        self.assertEqual(check["history_ms"][-2:], [200, None])

    def test_missing_probes_and_non_public_labels(self):
        now = 200_000
        data = status_export.snapshot([
            series("probe_success", [(now - 2, "1"), (now + 1, "0")]),
            series("probe_duration_seconds", [(now - 2, "0.048")]),
            series("probe_success", [(now, "1")], project="billing"),
        ], now)
        self.assertEqual(list(data["projects"]), list(status_export.PROJECTS))
        self.assertEqual(data["projects"]["bookreviews"]["duration_ms"], 48)
        self.assertIsNone(data["projects"]["portfolio"]["available"])
        self.assertIsNone(data["projects"]["portfolio"]["checked_at"])
        self.assertNotIn("example.invalid", json.dumps(data))

    def test_failed_write_preserves_previous_snapshot(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "data.json"
            status_export.publish(path, {"generated_at": 123})
            with self.assertRaises(ValueError):
                status_export.publish(path, {"generated_at": float("nan")})
            self.assertEqual(json.loads(path.read_text()), {"generated_at": 123})
            self.assertEqual(list(Path(directory).iterdir()), [path])
