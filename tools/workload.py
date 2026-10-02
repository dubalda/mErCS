"""Run P1-P9 in isolated Luau processes and compare a release with two control runs.

Usage: python tools/workload.py [--luau path] [runs=5] [baseline=v0.2.4]
       [tests=P1,P7] [scales=target] [modes=native] [release=yes] [output=tmp/workload]

The default covers the server, the alternate retained-agent lifecycle, the client and
retained snapshot buffers. Release mode rejects incomplete runs and measured regressions.
JSON retains every sample, seed, source hash and the measurement environment; Markdown
shows medians, ranges and a per-row noise allowance from paired baseline controls.
Only the Python standard library and the pinned Luau CLI are needed.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import statistics
import subprocess
import sys
import time
import tomllib

ROOT = Path(__file__).resolve().parent.parent
TESTS = tuple(f"P{i}" for i in range(1, 10))
GROUPS = ("sparse", "small", "target", "small-empty-retained", "target-empty-retained", "client", "buffers")
BUILDS = ("baseline", "baseline_again", "candidate", "candidate_again")
COUNTS = {"P2": 4, "P3": 1, "P4": 1, "P5": 2, "P6": 4, "P7": 2, "P8": 7, "P9": 3}


def checked(*command: str) -> bytes:
    return subprocess.run(command, cwd=ROOT, check=True, capture_output=True).stdout


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def parse_samples(output: str) -> dict[tuple[str, str, str, str], float]:
    rows = {}
    for line in output.splitlines():
        if not line.startswith("SAMPLE\t"):
            continue
        fields = line.split("\t")
        if len(fields) != 6:
            raise ValueError(f"malformed sample: {line}")
        key = tuple(fields[1:5])
        value = float(fields[5])
        if key in rows or not math.isfinite(value):
            raise ValueError(f"duplicate or non-finite sample: {line}")
        rows[key] = value
    if not rows:
        raise ValueError("the benchmark produced no samples")
    return rows


def expected_counts(group: str, selected: set[str]) -> dict[str, int]:
    if group == "sparse":
        counts = {"P1": 10}
    elif group == "client":
        counts = {"P4": 1, "P7": 1, "P8": 4, "P9": 1}
    elif group == "buffers":
        counts = {"P8": 2, "P9": 1}
    else:
        counts = COUNTS
    return {key: count for key, count in counts.items() if key in selected}


def compare(samples: dict[str, list[float]], unit: str, case: str) -> dict:
    a, b = samples["baseline"], samples["baseline_again"]
    c, d = samples["candidate"], samples["candidate_again"]
    if not a or len({len(a), len(b), len(c), len(d)}) != 1:
        raise ValueError("comparison requires equally sized paired controls")
    med = statistics.median
    # Use paired controls with identical seeds; variation in the model across seeds is
    # not charged as machine noise. The allowance is fixed using baseline samples only.
    resolution = 0.0
    if unit == "MB":
        resolution = 1 / 1024  # collectgarbage('count') is quantized to KiB
    elif unit == "bytes":
        resolution = 1024 / (60 if "frame" in case else 1 if "first" in case else 1000)
    noise = max(resolution, abs(med(a) - med(b)), 3 * med([abs(x - y) for x, y in zip(a, b)]))
    before, after = med(a + b), med(c + d)
    delta = after - before
    # A difference of exactly the allowance (one step of the heap resolution) is within it: the
    # rounding of the float subtraction must not turn it into a change.
    tolerance = 1e-9 * max(1.0, abs(before), abs(after))
    status = ("regression" if delta > noise + tolerance
              else "improved" if delta < -noise - tolerance else "within noise")
    return {
        "baseline": before,
        "candidate": after,
        "noise": noise,
        "delta": delta,
        "ratio": after / before if before > 0 else None,
        "status": status,
    }


def summarize(data: dict) -> tuple[str, list[dict]]:
    rows = {}
    for sample in data["samples"]:
        for row in sample["rows"]:
            key = (sample["mode"], *row[:4])
            builds = rows.setdefault(key, {build: [] for build in BUILDS})
            builds[sample["build"]].append(row[4])
    comparisons = []
    lines = [
        "# Performance on the reference workload",
        "",
        f"Baseline: `{data['baseline']['tag']}` / `{data['baseline']['commit']}`.",
        f"Candidate source SHA-256: `{data['candidate_sha256']}`.",
        f"Luau executable SHA-256: `{data['luau_sha256']}`; pinned version: `{data['luau_version']}`.",
        f"Environment: {data['environment']}; {data['runs']} samples per build/control and mode.",
        "",
        "Every build/control/profile runs in a fresh process. Each cell is median [min–max].",
        "Noise allowance: max(baseline control median difference, 3 × median paired absolute",
        "control difference, heap measurement resolution). No candidate result widens this allowance.",
        "P9 frame rows are net heap growth with GC checked, not total allocator traffic.",
        "Memory units labelled MB are MiB (1024² bytes). Full samples and environment are in the adjacent JSON.",
        "",
        "| Mode | Test | Case | Scale | Unit | Baseline | Baseline again | Candidate | Candidate again | Ratio | Noise | Result |",
        "|---|---|---|---|---|---|---|---|---|---|---|---|",
    ]
    for key, samples in sorted(rows.items()):
        mode, test, case, scale, unit = key
        stats = compare(samples, unit, case)
        comparisons.append({"mode": mode, "test": test, "case": case, "scale": scale, "unit": unit, **stats})
        cells = [mode, test, case, scale, unit]
        for build in BUILDS:
            values = samples[build]
            cells.append(f"{statistics.median(values):.6g} [{min(values):.6g}–{max(values):.6g}]")
        cells.extend([
            f"{stats['ratio']:.4f}×" if stats["ratio"] is not None else "—",
            f"{stats['noise']:.6g}", stats["status"],
        ])
        lines.append("| " + " | ".join(cells) + " |")
    return "\n".join(lines) + "\n", comparisons


def options(arguments: list[str]) -> dict:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--luau", default="luau")
    parser.add_argument("settings", nargs="*")
    parsed = parser.parse_args(arguments)
    settings = {"runs": "5", "baseline": "v0.2.4", "tests": ",".join(TESTS),
                "scales": ",".join(GROUPS), "modes": "interpreter,native", "release": "no",
                "output": "tmp/workload"}
    for setting in parsed.settings:
        key, sep, value = setting.partition("=")
        if not sep or key not in settings or not value:
            parser.error(f"unknown or empty setting: {setting}")
        settings[key] = value
    try:
        settings["runs"] = int(settings["runs"])
    except ValueError:
        parser.error("runs must be an integer")
    settings["tests"] = set(settings["tests"].split(","))
    settings["scales"] = settings["scales"].split(",")
    settings["modes"] = settings["modes"].split(",")
    if settings["runs"] < 1 or not settings["tests"] <= set(TESTS):
        parser.error("invalid runs or tests")
    if not set(settings["scales"]) <= set(GROUPS) or not set(settings["modes"]) <= {"interpreter", "native"}:
        parser.error("unknown scale or mode")
    if len(set(settings["scales"])) != len(settings["scales"]) or len(set(settings["modes"])) != len(settings["modes"]):
        parser.error("duplicate scale or mode")
    if settings["release"] not in {"yes", "no"}:
        parser.error("release must be yes or no")
    if settings["release"] == "yes" and (
        settings["runs"] < 5 or settings["tests"] != set(TESTS)
        or set(settings["scales"]) != set(GROUPS) or set(settings["modes"]) != {"interpreter", "native"}
    ):
        parser.error("release mode requires all P1-P9, profiles, modes and at least five runs")
    settings["luau"] = parsed.luau
    return settings


def main(arguments: list[str]) -> int:
    settings = options(arguments)
    tag = settings["baseline"]
    if not tag.startswith("v") or any(c not in "v0123456789." for c in tag):
        raise ValueError("baseline must be a release tag vX.Y.Z")
    commit = checked("git", "rev-parse", "--verify", f"refs/tags/{tag}^{{commit}}").decode().strip()
    baseline = checked("git", "show", f"refs/tags/{tag}:src/init.luau")
    candidate = (ROOT / "src/init.luau").read_bytes()
    output = (ROOT / settings["output"]).resolve()
    output.mkdir(parents=True, exist_ok=True)
    paths = {}
    for build, source in (("baseline", baseline), ("candidate", candidate)):
        destination = output / build
        destination.mkdir(exist_ok=True)
        (destination / "init.luau").write_bytes(source)
        paths[build] = os.path.relpath(destination, ROOT / "bench").replace("\\", "/")
        if not paths[build].startswith("."):
            paths[build] = "./" + paths[build]
    logs = output / "logs"
    logs.mkdir(exist_ok=True)
    import shutil
    executable = Path(shutil.which(settings["luau"]) or settings["luau"])
    toolchain = tomllib.loads((ROOT / "rokit.toml").read_text(encoding="utf-8"))
    suite = {str(path.relative_to(ROOT)): digest(path.read_bytes()) for path in (ROOT / "bench").glob("workload*.luau")}
    suite["bench/gc.luau"] = digest((ROOT / "bench/gc.luau").read_bytes())
    suite["tools/workload.py"] = digest(Path(__file__).read_bytes())
    data = {
        "baseline": {"tag": tag, "commit": commit, "sha256": digest(baseline)},
        "candidate_sha256": digest(candidate), "luau_sha256": digest(executable.read_bytes()),
        "luau_version": toolchain["tools"]["luau"], "suite_sha256": suite,
        "environment": f"{platform.platform()} / {platform.processor()}",
        "runs": settings["runs"], "samples": [], "started": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "release_requested": settings["release"] == "yes", "complete": False,
        "tests": sorted(settings["tests"]), "profiles": settings["scales"], "modes": settings["modes"],
    }
    # A failed rerun must not leave the previous run's report looking current.
    (output / "report.md").unlink(missing_ok=True)
    (output / "samples.json").write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")
    expected_keys = {}
    total = 0
    started = time.monotonic()
    for mode in settings["modes"]:
        for run in range(settings["runs"]):
            for group in settings["scales"]:
                expected = expected_counts(group, settings["tests"])
                if not expected:
                    continue
                order = BUILDS[run % 4:] + BUILDS[:run % 4]
                for build in order:
                    arguments = [str(executable), "-O2"] + (["--codegen"] if mode == "native" else [])
                    arguments += ["bench/workload.luau", "-a", "runs=1", "raw=yes", f"seed={1001 + run}",
                                  f"implementation={paths[build.split('_')[0]]}", f"tests={','.join(sorted(expected))}"]
                    if group in {"client", "buffers"}:
                        arguments.append(f"profile={group}")
                    elif group == "sparse":
                        arguments.append("scales=none")
                    else:
                        arguments.append(f"scales={group.split('-')[0]}")
                        if group.endswith("empty-retained"):
                            arguments.append("retained=empty")
                    result = subprocess.run(arguments, cwd=ROOT, capture_output=True, encoding="utf-8", errors="replace")
                    log_path = logs / f"{mode}-{group}-{run + 1}-{build}.log"
                    log_path.write_text(result.stdout + result.stderr, encoding="utf-8")
                    if result.returncode:
                        raise RuntimeError(f"benchmark failed ({result.returncode}): {log_path}\n{result.stderr}")
                    rows = parse_samples(result.stdout)
                    counts = {test: sum(key[0] == test for key in rows) for test in expected}
                    if counts != expected or any(key[0] not in expected for key in rows):
                        raise ValueError(f"incomplete benchmark rows: {group}: {counts}, expected {expected}")
                    if group in expected_keys and set(rows) != expected_keys[group]:
                        raise ValueError(f"row identities changed between builds: {group}")
                    expected_keys[group] = set(rows)
                    data["samples"].append({"mode": mode, "group": group, "build": build, "seed": 1001 + run,
                                            "rows": [[*key, value] for key, value in rows.items()]})
                    (output / "samples.json").write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")
                    total += 1
                print(f"{mode}: run {run + 1}/{settings['runs']}, {group}; {total} processes, {time.monotonic() - started:.0f}s", flush=True)
    if not data["samples"]:
        raise ValueError("selected tests and profiles produced no measurements")
    for filename, expected in suite.items():
        if digest((ROOT / filename).read_bytes()) != expected:
            raise ValueError(f"benchmark source changed during the run: {filename}")
    if digest((ROOT / "src/init.luau").read_bytes()) != data["candidate_sha256"]:
        raise ValueError("candidate source changed during the run; rerun against the final source")
    report, comparisons = summarize(data)
    regressions = [row for row in comparisons if row["status"] == "regression"]
    progress = [row for row in comparisons if row["status"] == "improved"]
    data.update(complete=True, comparisons=comparisons, elapsed_seconds=time.monotonic() - started)
    data["performance_gate"] = "pass" if not regressions and progress else "review required"
    (output / "samples.json").write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")
    (output / "report.md").write_text(report, encoding="utf-8")
    print(f"Report: {output / 'report.md'}; {len(progress)} improved, {len(regressions)} require regression review")
    for row in regressions:
        print(f"  {row['mode']} {row['test']} {row['scale']}: {row['case']} ({row['ratio']})")
    return 1 if settings["release"] == "yes" and (regressions or not progress) else 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except (ValueError, RuntimeError, OSError, subprocess.CalledProcessError) as error:
        print(f"workload: {error}", file=sys.stderr)
        raise SystemExit(1)
