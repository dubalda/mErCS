"""Check that the analyzer rejects the misuses of the public types in test/typecheck/errors.luau.

Every line of the file marked with a trailing comment `error: <text>` must get at least one
error whose message contains <text>, and no other line may get an error. A run that reports no
error, an error in another file and a file without marked lines are failures too, so that a
broken analyzer or a moved file cannot pass. tools/check.sh runs it with the analyzer and the
type definitions that it uses for the rest of the repository; the analyzer runs with the same
flags. tools/test_typecheck.py tests the comparison.

Usage: python tools/typecheck.py <luau-lsp> <roblox type definitions>
"""

from __future__ import annotations

from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
FIXTURE = "test/typecheck/errors.luau"
ENTRY = re.compile(r"^(?P<path>.+?)\((?P<line>\d+),(?P<column>\d+)\): (?P<kind>\w+): (?P<message>.*)$")
MARK = re.compile(r"--\s*error:\s*(?P<text>.+?)\s*$")


def parse(output: str, fixture: str = FIXTURE) -> tuple[dict[int, list[str]], list[str]]:
    """The errors of the fixture by line (each message joined from its lines), and other errors."""
    errors: dict[int, list[str]] = {}
    foreign: list[str] = []
    last: int | None = None  # the line whose last message the next lines continue
    for raw in output.splitlines():
        if raw.startswith(("[INFO]", "[WARN]")):
            continue
        match = ENTRY.match(raw)
        if match:
            if Path(match["path"]).as_posix() != fixture:
                foreign.append(raw)
                last = None
                continue
            last = int(match["line"])
            errors.setdefault(last, []).append(f"{match['kind']}: {match['message'].strip()}")
        elif last is not None and raw.strip():
            errors[last][-1] += " " + raw.strip()
    return errors, foreign


def marks(source: str) -> dict[int, str]:
    """The expected error text of every marked line of code (not of comments)."""
    expected: dict[int, str] = {}
    in_block = False  # inside a --[[ ]] comment, which only describes the marks
    for number, line in enumerate(source.splitlines(), 1):
        code = line.strip()
        if in_block:
            in_block = "]]" not in code
            continue
        if code.startswith("--[["):
            in_block = "]]" not in code
            continue
        mark = MARK.search(line)
        if mark and not code.startswith("--"):
            expected[number] = mark["text"]
    return expected


def check(output: str, source: str, fixture: str = FIXTURE) -> list[str]:
    """The failures of an analyzer run over the fixture: missing, unexpected and foreign errors."""
    errors, foreign = parse(output, fixture)
    expected = marks(source)
    failures: list[str] = []
    if not expected:
        failures.append(f"{fixture}: no line is marked with an expected error")
    if not errors and not foreign:
        failures.append(f"the analyzer reported no error:\n{output}")
    for line in foreign:
        failures.append(f"an error outside {fixture}: {line}")
    for number, text in sorted(expected.items()):
        messages = errors.get(number, [])
        if not any(text in message for message in messages):
            got = "; ".join(messages) if messages else "no error"
            failures.append(f"{fixture}:{number}: expected an error containing {text!r}, got {got}")
    for number, messages in sorted(errors.items()):
        if number not in expected:
            failures.append(f"{fixture}:{number}: unexpected error: {'; '.join(messages)}")
    return failures


def main(arguments: list[str]) -> int:
    if len(arguments) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    analyzer, definitions = arguments
    result = subprocess.run(
        [analyzer, "analyze", "--flag:LuauSolverV2=true", "--platform", "roblox",
         f"--definitions:@roblox={definitions}", FIXTURE],
        cwd=ROOT, capture_output=True, text=True, encoding="utf-8", errors="replace",
    )
    source = (ROOT / FIXTURE).read_text(encoding="utf-8")
    failures = check(result.stdout + result.stderr, source)
    if failures:
        print("\n".join(failures), file=sys.stderr)
        return 1
    print(f"typecheck: {len(marks(source))} misuses rejected as expected")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
