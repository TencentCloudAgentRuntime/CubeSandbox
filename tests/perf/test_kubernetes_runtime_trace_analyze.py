#!/usr/bin/env python3

import importlib.util
import pathlib
import unittest


MODULE_PATH = pathlib.Path(__file__).with_name("kubernetes_runtime_trace_analyze.py")
SPEC = importlib.util.spec_from_file_location("kubernetes_runtime_trace_analyze", MODULE_PATH)
ANALYZER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ANALYZER)


def event(component, phase, timestamp, duration=None, uid="pod-1", sandbox="sandbox-1"):
    row = {
        "component": component,
        "operation": "create" if component == "shim" else "run-pod-sandbox",
        "phase": phase,
        "pod_uid": uid,
        "sandbox_id": sandbox,
        "ts_mono_us": timestamp,
    }
    if duration is not None:
        row["duration_us"] = duration
    return row


class TraceAnalyzerTest(unittest.TestCase):
    def test_nearest_rank(self):
        values = list(range(1, 51))
        self.assertEqual(ANALYZER.nearest_rank(values, 0.95), 48)
        self.assertEqual(ANALYZER.nearest_rank(values, 0.99), 50)

    def test_non_overlapping_timeline(self):
        rows = [
            event("containerd", "cri-receive", 100),
            event("containerd", "id-generated", 101),
            event("containerd", "cni-setup", 130, 20),
            event("containerd", "controller-create-begin", 132),
            event("containerd", "shim-manager-start-begin", 135),
            event("containerd", "binary-start-begin", 138),
            event("containerd", "shim-bootstrap-process", 160, 20),
            event("containerd", "shim-connect", 162, 1),
            event("containerd", "shim-create-rpc", 200, 35),
            event("containerd", "controller-create", 240, 108),
            event("containerd", "cri-return", 500),
        ]
        shim = [event("shim", "ttrpc-total", 240, 74)]
        result = ANALYZER.analyze(rows, shim, {"pod-1"}, "serial")
        sample = result["samples"][0]
        self.assertEqual(sample["cri_to_shim_create_begin_us"], 66)
        self.assertEqual(sample["pre_shim_component_sum_us"], 66)
        self.assertEqual(sample["pre_shim_residual_us"], 0)
        self.assertTrue(result["gate_pass"])

    def test_duplicate_phase_is_rejected(self):
        rows = [event("containerd", phase, index + 1) for index, phase in enumerate(ANALYZER.REQUIRED_CONTAINERD_PHASES)]
        rows.append(event("containerd", "cri-receive", 20))
        with self.assertRaisesRegex(ValueError, "duplicates"):
            ANALYZER.analyze(rows, [event("shim", "ttrpc-total", 30, 1)], {"pod-1"}, "serial")

    def test_unrelated_uid_is_ignored(self):
        rows = [
            event("containerd", phase, index + 100, uid="unrelated", sandbox="other")
            for index, phase in enumerate(ANALYZER.REQUIRED_CONTAINERD_PHASES)
        ]
        with self.assertRaisesRegex(ValueError, "missing"):
            ANALYZER.analyze(rows, [], {"pod-1"}, "serial")


if __name__ == "__main__":
    unittest.main()
