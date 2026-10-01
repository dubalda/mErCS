"""Check workload evidence parsing and release gates without running timing benchmarks.

Run: python -B -m unittest discover -s tools -p 'test_workload.py'
"""

import contextlib
import io
import subprocess
import unittest
from unittest.mock import patch

import workload


class WorkloadTests(unittest.TestCase):
    def options_error(self, *arguments):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
            workload.options(list(arguments))
        self.assertEqual(error.exception.code, 2)

    def test_release_requires_all_modes_profiles_tests_and_five_runs(self):
        self.assertEqual(workload.options(["release=yes"])["runs"], 5)
        for argument in ("runs=4", "tests=P1,P7", "scales=target", "modes=native"):
            with self.subTest(argument=argument):
                self.options_error("release=yes", argument)

    def test_invalid_selection_does_not_silently_skip_measurements(self):
        for argument in ("runs=0", "runs=abc", "runs=1.5", "tests=P10", "scales=none",
                         "modes=jit", "modes=native,native", "scales=target,target", "release=maybe"):
            with self.subTest(argument=argument):
                self.options_error(argument)

    def test_missing_or_invalid_baseline_cannot_use_a_stale_copy(self):
        with patch.object(workload, "checked") as checked:
            with self.assertRaises(ValueError):
                workload.main(["baseline=HEAD"])
            checked.assert_not_called()
        with patch.object(workload, "checked", side_effect=subprocess.CalledProcessError(1, "git")):
            with self.assertRaises(subprocess.CalledProcessError):
                workload.main(["baseline=v9.9.9"])

    def test_samples_accept_console_noise_but_require_complete_unique_finite_rows(self):
        sample = "SAMPLE\tP1\t16 members\tsparse\tµs per loop\t1.23456789"
        self.assertEqual(workload.parse_samples("header\n" + sample + "\nfooter"),
                         {("P1", "16 members", "sparse", "µs per loop"): 1.23456789})
        for output in ("no measurements", sample + "\n" + sample, "SAMPLE\tP1\tbroken",
                       sample.rsplit("\t", 1)[0] + "\tnan", sample.rsplit("\t", 1)[0] + "\tinf"):
            with self.subTest(output=output), self.assertRaises(ValueError):
                workload.parse_samples(output)

    def test_coverage_distinguishes_all_profiles(self):
        selected = set(workload.TESTS)
        self.assertEqual(workload.expected_counts("sparse", selected), {"P1": 7})
        self.assertEqual(workload.expected_counts("client", selected), {"P4": 1, "P7": 1, "P8": 4, "P9": 1})
        self.assertEqual(workload.expected_counts("buffers", selected), {"P8": 2, "P9": 1})
        for group in ("small", "target", "small-empty-retained", "target-empty-retained"):
            self.assertEqual(sum(workload.expected_counts(group, selected).values()), 20)
            self.assertEqual(workload.expected_counts(group, {"P7"}), {"P7": 2})

    def test_noise_uses_paired_baseline_controls_not_seed_variance_or_candidate_noise(self):
        samples = {"baseline": [100, 200, 300, 400, 500],
                   "baseline_again": [101, 201, 301, 401, 501],
                   "candidate": [110, 210, 310, 410, 510],
                   "candidate_again": [120, 220, 320, 420, 520]}
        result = workload.compare(samples, "µs per frame", "frame")
        self.assertEqual(result["noise"], 3)
        self.assertEqual(result["status"], "regression")
        samples["candidate_again"] = [1, 1, 9999, 9999, 9999]
        self.assertEqual(workload.compare(samples, "µs per frame", "frame")["noise"], 3)

    def test_compare_reports_progress_and_respects_measurement_resolution(self):
        samples = {build: [100] * 5 for build in workload.BUILDS}
        for build in ("candidate", "candidate_again"):
            samples[build] = [99] * 5
        self.assertEqual(workload.compare(samples, "µs", "time")["status"], "improved")
        self.assertEqual(workload.compare(samples, "bytes", "frame heap")["status"], "within noise")
        self.assertEqual(workload.compare(samples, "bytes", "frame heap")["noise"], 1024 / 60)
        samples["baseline_again"] = []
        with self.assertRaises(ValueError):
            workload.compare(samples, "µs", "time")

    def test_report_keeps_raw_values_and_distinct_modes_and_scales(self):
        data = {"baseline": {"tag": "v0.2.3", "commit": "commit"}, "candidate_sha256": "candidate",
                "luau_sha256": "luau", "luau_version": "0.740", "environment": "test", "runs": 5, "samples": []}
        for mode in ("native", "interpreter"):
            for scale in ("small", "target", "target-empty-retained"):
                for build in workload.BUILDS:
                    for seed in range(5):
                        value = 100 + seed if build.startswith("baseline") else 90 + seed
                        data["samples"].append({"mode": mode, "build": build, "seed": seed,
                                                "rows": [["P7", "frame", scale, "µs", value]]})
        report, comparisons = workload.summarize(data)
        self.assertEqual(len(comparisons), 6)
        self.assertTrue(all(row["status"] == "improved" for row in comparisons))
        self.assertIn("102 [100–104]", report)
        self.assertIn("92 [90–94]", report)
        self.assertEqual(data["samples"][0]["rows"][0][-1], 100)


if __name__ == "__main__":
    unittest.main()
