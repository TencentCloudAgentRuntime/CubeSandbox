import importlib.util
import json
import os
import pathlib
import tempfile
import unittest
from unittest import mock


RUNNER_PATH = pathlib.Path(__file__).with_name("runner.py")
SPEC = importlib.util.spec_from_file_location("scale_load_runner", RUNNER_PATH)
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)


class LoadRunObserveTest(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        template_path = pathlib.Path(self.tempdir.name) / "pod.json"
        template_path.write_text(json.dumps({"apiVersion": "v1", "kind": "Pod", "spec": {}}))
        self.environment = mock.patch.dict(
            os.environ,
            {
                "RUN_ID": "test",
                "TARGET_NAMESPACES": "test-ns",
                "POD_COUNT": "2",
                "CREATE_QPS": "2",
                "CREATE_WORKERS": "1",
                "WORKLOAD_PROFILE": "simple",
                "STAGE": "test",
                "SNAPSHOTTER_PROFILE": "overlayfs",
                "LOAD_IMAGE": "example.invalid/load@sha256:test",
                "CUBE_TEMPLATE_MODE": "test",
                "TEMPLATE_PATH": str(template_path),
                "OUTPUT_DIR": self.tempdir.name,
            },
            clear=True,
        )
        self.environment.start()
        self.run = RUNNER.LoadRun()

    def tearDown(self):
        self.environment.stop()
        self.tempdir.cleanup()

    def observe_ready(self, index, status="True", resource_version="1"):
        self.run.observe(
            {
                "metadata": {
                    "namespace": "test-ns",
                    "name": f"cube-cri-test-{index:05d}",
                    "resourceVersion": resource_version,
                },
                "spec": {"containers": []},
                "status": {
                    "conditions": [
                        {
                            "type": "Ready",
                            "status": status,
                            "lastTransitionTime": "2026-09-17T00:00:00Z",
                        }
                    ]
                },
            },
            observed_ns=int(resource_version),
            observed_wall_ns=int(resource_version),
        )

    def test_ready_count_only_increments_on_first_observation(self):
        self.observe_ready(0)
        self.observe_ready(0, resource_version="2")
        self.assertEqual(self.run.ready_count, 1)
        self.assertFalse(self.run.done.is_set())

        self.observe_ready(1, status="False", resource_version="3")
        self.assertEqual(self.run.ready_count, 1)

        self.observe_ready(1, resource_version="4")
        self.assertEqual(self.run.ready_count, 2)
        self.assertTrue(self.run.done.is_set())

        self.observe_ready(0, status="False", resource_version="5")
        self.observe_ready(0, resource_version="6")
        self.assertEqual(self.run.ready_count, 2)
        self.assertTrue(self.run.records[("test-ns", "cube-cri-test-00000")]["readyLost"])


if __name__ == "__main__":
    unittest.main()
