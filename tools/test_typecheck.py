"""Tests of the comparison in tools/typecheck.py, without running the analyzer.

Run: python -B -m unittest discover -s tools -p 'test_*.py'
"""

import unittest

import typecheck

FIXTURE = "test/typecheck/errors.luau"
SOURCE = """--[[
    a description that mentions a mark: x -- error: not a mark
]]
local a = 1
f(a) -- error: but got 'string'
-- g(a) -- error: a comment, not a mark
h(a) -- error: No valid instantiation
"""


def error(line: int, message: str, path: str = FIXTURE) -> str:
    return f"{path}({line},1): TypeError: {message}"


class TypecheckTests(unittest.TestCase):
    def test_marks_skip_comments(self):
        self.assertEqual(typecheck.marks(SOURCE), {5: "but got 'string'", 7: "No valid instantiation"})

    def test_expected_errors_pass_also_over_several_lines(self):
        output = "\n".join([
            "[INFO] analyzing",
            error(5, "Expected this to be 'number', but got 'string'"),
            error(7, "No valid instantiation could be inferred for generic type parameter T. It was"),
            "\texpected to be at least:",
        ])
        self.assertEqual(typecheck.check(output, SOURCE), [])

    def test_a_missing_expected_error_fails(self):
        failures = typecheck.check(error(5, "but got 'string'"), SOURCE)
        self.assertEqual(len(failures), 1)
        self.assertIn(":7: expected an error containing 'No valid instantiation', got no error", failures[0])

    def test_an_error_of_another_text_fails(self):
        output = "\n".join([error(5, "but got 'number'"), error(7, "No valid instantiation")])
        self.assertIn("expected an error containing", typecheck.check(output, SOURCE)[0])

    def test_unexpected_and_foreign_errors_fail(self):
        output = "\n".join([
            error(5, "but got 'string'"), error(7, "No valid instantiation"),
            error(4, "something else"), error(1, "elsewhere", "test/other.luau"),
        ])
        failures = typecheck.check(output, SOURCE)
        self.assertTrue(any("unexpected error" in failure and ":4:" in failure for failure in failures))
        self.assertTrue(any("an error outside" in failure for failure in failures))

    def test_a_run_without_errors_or_marks_fails(self):
        self.assertTrue(any("reported no error" in failure for failure in typecheck.check("", SOURCE)))
        self.assertTrue(any("no line is marked" in failure for failure in typecheck.check(error(1, "x"), "local a = 1\n")))


if __name__ == "__main__":
    unittest.main()
