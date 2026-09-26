"""
Regenerates the specialized query iterator sections of src/init.luau.

The query iterators are written once per number of returned values (0..8) because a
generic loop over columns costs far more than the iteration itself in Luau. This script
rewrites the code between the markers

    -- @generated <name> begin
    -- @generated <name> end

in src/init.luau: the direct for-in iterators (bitset spans), the list iterators (the match
list of a cached query) and the matching each() loops. Run from the repository root, then
format:

    python tools/generate.py && stylua src
"""

import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
TARGET = ROOT / "src" / "init.luau"
T = "    "
MAX_VALUES = 8


def values(n: int, prefix: str, index: str) -> str:
    return "".join(f", {prefix}{k}[{index}]" for k in range(1, n + 1))


def page_reload(n: int, indent: str, source: str) -> list[str]:
    lines = []
    for k in range(1, n + 1):
        lines.append(f"{indent}p{k} = cp{k}[{source}] or EMPTY")
    return lines


WIDE = MAX_VALUES + 1  # more than MAX_VALUES values: the rest are returned through a table


def wide_setup(indent: str) -> list[str]:
    i = indent
    return [
        f"{i}local nx = n - {MAX_VALUES}",
        f"{i}local xcp: {{ Pages }} = table.create(nx) :: {{ Pages }}",
        f"{i}for k = 1, nx do",
        f"{i}{T}xcp[k] = columns[ids[{MAX_VALUES} + k]] or EMPTY_PAGES",
        f"{i}end",
        f"{i}local xp: {{ Page }} = table.create(nx, EMPTY) :: {{ Page }}",
        f"{i}local xout = table.create(nx)",
    ]


def wide_fill(indent: str, pages: str) -> list[str]:
    return [f"{indent}for k = 1, nx do", f"{indent}{T}xout[k] = {pages}[k][li]", f"{indent}end"]


def direct_iterator(n: int, indent: str) -> list[str]:
    """for-in over bitsets; the control variable carries the previous entity.

    Order of the paths: the current run of matching slots, the remaining bits of a partial
    word (pmask), a deleted entity returned by the previous step, the next span.
    """
    i = indent
    wide = n == WIDE
    if wide:
        n = MAX_VALUES
    rest = ", table.unpack(xout, 1, nx)" if wide else ""
    hot = values(n, "q", "li") + rest
    slow = values(n, "p", "li") + rest
    copy = []
    if n > 0:
        copy = [f"{i}{T}local {', '.join(f'q{k}' for k in range(1, n + 1))} = {', '.join(f'p{k}' for k in range(1, n + 1))}"]
    if wide:
        copy.append(f"{i}{T}local xq = xp")

    def li(ind: str, pages: str) -> list[str]:
        if n == 0:
            return []
        return [f"{ind}local li = s - page_offset"] + (wide_fill(ind, pages) if wide else [])

    reload = page_reload(n, f"{i}{T}", "page")
    if wide:
        reload += [f"{i}{T}for k = 1, nx do", f"{i}{T}{T}xp[k] = xcp[k][page] or EMPTY", f"{i}{T}end"]
    return (
        [
            f"{i}step = function(_: any, prev: i53): ...any",
            f"{i}{T}local s = band(prev, SLOT_BITS) + 1",
        ]
        + copy
        + [f"{i}{T}if s <= run_last then"]
        + li(f"{i}{T}{T}", "xq")
        + [
            f"{i}{T}{T}return alive[s]{hot}",
            f"{i}{T}end",
            f"{i}{T}local m = pmask",
            f"{i}{T}if m ~= 0 then",
            f"{i}{T}{T}s = pbase + countrz(m)",
            f"{i}{T}{T}pmask = band(m, m - 1)",
        ]
        + li(f"{i}{T}{T}", "xq")
        + [
            f"{i}{T}{T}return alive[s]{hot}",
            f"{i}{T}end",
            f"{i}{T}if prev < 0 then",
            f"{i}{T}{T}-- the previous entity was deleted meanwhile: continue after its slot",
            f"{i}{T}{T}s = (-1 - prev) // ENTITY_MASK + 1",
            f"{i}{T}{T}if s <= run_last then",
        ]
        + li(f"{i}{T}{T}{T}", "xq")
        + [
            f"{i}{T}{T}{T}return alive[s]{hot}",
            f"{i}{T}{T}end",
            f"{i}{T}end",
            f"{i}{T}local first, last, span_mask = advance()",
            f"{i}{T}if first == nil then",
            f"{i}{T}{T}ctx.busy = false",
            f"{i}{T}{T}return nil",
            f"{i}{T}end",
            f"{i}{T}local page = first // PAGE_SIZE + 1",
            f"{i}{T}if page ~= cur_page then",
            f"{i}{T}{T}cur_page = page",
        ]
        + [T + line for line in reload]
        + [
            f"{i}{T}{T}page_offset = (page - 1) * PAGE_SIZE - 1",
            f"{i}{T}end",
            f"{i}{T}if span_mask == FULL_WORD then",
            f"{i}{T}{T}run_last = last :: number",
            f"{i}{T}{T}s = first",
            f"{i}{T}else",
            f"{i}{T}{T}run_last = -1",
            f"{i}{T}{T}pbase = first",
            f"{i}{T}{T}s = first + countrz(span_mask)",
            f"{i}{T}{T}pmask = band(span_mask, span_mask - 1)",
            f"{i}{T}end",
        ]
        + li(f"{i}{T}", "xp")
        + [
            f"{i}{T}return alive[s]{slow}",
            f"{i}end",
        ]
    )


def list_iterator(n: int, indent: str) -> list[str]:
    """for-in over the match list of a cached query; page references change per group.

    Returns the step function and a reset function: a cached query reuses both across
    iterations. The first time the step reaches the end it clears query.list_busy and counts
    the loop out of query.list_readers.
    """
    i = indent
    if n == 0:
        return [
            f"{i}local j, done = 0, false",
            f"{i}return function(): ...any",
            f"{i}{T}local k = j + 1",
            f"{i}{T}j = k",
            f"{i}{T}local e = entities[k]",
            f"{i}{T}if e == nil and not done then",
            f"{i}{T}{T}done = true",
            f"{i}{T}{T}query.list_busy = false",
            f"{i}{T}{T}query.list_readers -= 1",
            f"{i}{T}end",
            f"{i}{T}return e",
            f"{i}end, function()",
            f"{i}{T}j, done = 0, false",
            f"{i}end",
        ]
    pages = ", ".join(f"p{k}" for k in range(1, n + 1))
    vals = "".join(f", p{k}[li]" for k in range(1, n + 1))
    # the position is read into a local once: every read of an upvalue costs
    return (
        [
            f"{i}local j, g, group_last = 0, 0, 0",
            f"{i}local {pages} = " + ", ".join("EMPTY" for _ in range(n)),
            f"{i}return function(): ...any",
            f"{i}{T}local k = j + 1",
            f"{i}{T}j = k",
            f"{i}{T}if k > group_last then",
            f"{i}{T}{T}local next_g = g + 1",
            f"{i}{T}{T}local last = ends[next_g]",
            f"{i}{T}{T}if last == nil then",
            f"{i}{T}{T}{T}if g >= 0 then",
            f"{i}{T}{T}{T}{T}g = -1 -- the end is counted once",
            f"{i}{T}{T}{T}{T}query.list_busy = false",
            f"{i}{T}{T}{T}{T}query.list_readers -= 1",
            f"{i}{T}{T}{T}end",
            f"{i}{T}{T}{T}return nil",
            f"{i}{T}{T}end",
            f"{i}{T}{T}g = next_g",
            f"{i}{T}{T}group_last = last",
        ]
        + [f"{i}{T}{T}p{k} = g{k}[next_g]" for k in range(1, n + 1)]
        + [
            f"{i}{T}end",
            f"{i}{T}local li = locals[k]",
            f"{i}{T}return entities[k]{vals}",
            f"{i}end, function()",
            f"{i}{T}j, g, group_last = 0, 0, 0",
            f"{i}end",
        ]
    )


def direct_each(n: int, indent: str) -> list[str]:
    """Callback loop over bitset spans."""
    i = indent
    wide = n == WIDE
    if wide:
        n = MAX_VALUES
    vals = values(n, "p", "li") + (", table.unpack(xout, 1, nx)" if wide else "")

    def li(ind: str) -> list[str]:
        if n == 0:
            return []
        return [f"{ind}local li = s - page_offset"] + (wide_fill(ind, "xp") if wide else [])

    decl = []
    if n > 0:
        decl = [f"{i}{T}local {', '.join(f'p{k}' for k in range(1, n + 1))} = " + ", ".join(
            f"cp{k}[page] or EMPTY" for k in range(1, n + 1))]
    if wide:
        decl += [f"{i}{T}for k = 1, nx do", f"{i}{T}{T}xp[k] = xcp[k][page] or EMPTY", f"{i}{T}end"]
    page_lines = []
    if n > 0:
        page_lines = [f"{i}{T}local page = first // PAGE_SIZE + 1"] + decl + [
            f"{i}{T}local page_offset = (page - 1) * PAGE_SIZE - 1"
        ]
    return (
        (wide_setup(i) if wide else [])
        + [
            f"{i}while true do",
            f"{i}{T}local first, last, m = advance()",
            f"{i}{T}if first == nil then",
            f"{i}{T}{T}break",
            f"{i}{T}end",
        ]
        + page_lines
        + [
            f"{i}{T}if m == FULL_WORD then",
            f"{i}{T}{T}for s = first, last :: number do",
            f"{i}{T}{T}{T}local e = alive[s]",
            f"{i}{T}{T}{T}if e > 0 then",
        ]
        + li(f"{i}{T}{T}{T}{T}")
        + [
            f"{i}{T}{T}{T}{T}callback(e{vals})",
            f"{i}{T}{T}{T}end",
            f"{i}{T}{T}end",
            f"{i}{T}else",
            f"{i}{T}{T}repeat",
            f"{i}{T}{T}{T}local s = first + countrz(m)",
            f"{i}{T}{T}{T}m = band(m, m - 1)",
            f"{i}{T}{T}{T}local e = alive[s]",
            f"{i}{T}{T}{T}if e > 0 then",
        ]
        + li(f"{i}{T}{T}{T}{T}")
        + [
            f"{i}{T}{T}{T}{T}callback(e{vals})",
            f"{i}{T}{T}{T}end",
            f"{i}{T}{T}until m == 0",
            f"{i}{T}end",
            f"{i}end",
        ]
    )


def list_each(n: int, indent: str) -> list[str]:
    """Callback loop over the match list of a cached query, group by group."""
    i = indent
    if n == 0:
        return [f"{i}for j = 1, count do", f"{i}{T}callback(entities[j])", f"{i}end"]
    vals = "".join(f", p{k}[li]" for k in range(1, n + 1))
    return (
        [
            f"{i}local k = 0",
            f"{i}for g = 1, groups do",
            f"{i}{T}local {', '.join(f'p{k}' for k in range(1, n + 1))} = " + ", ".join(f"g{k}[g]" for k in range(1, n + 1)),
            f"{i}{T}local last = ends[g]",
            f"{i}{T}for j = k + 1, last do",
            f"{i}{T}{T}local li = locals[j]",
            f"{i}{T}{T}callback(entities[j]{vals})",
            f"{i}{T}end",
            f"{i}{T}k = last",
            f"{i}end",
        ]
    )


def chain(fn, indent_level: int, wide: bool = False) -> str:
    out = []
    ind = T * indent_level
    for n in range(0, MAX_VALUES + 1):
        keyword = "if" if n == 0 else "elseif"
        out.append(f"{ind}{keyword} n == {n} then")
        out.extend(fn(n, ind + T))
    if wide:
        out.append(f"{ind}else")
        out.extend(fn(WIDE, ind + T))
    out.append(f"{ind}end")
    return "\n".join(out)


def list_each_chain(indent_level: int) -> str:
    out = []
    ind = T * indent_level
    for n in range(0, MAX_VALUES + 1):
        keyword = "if" if n == 0 else "elseif"
        out.append(f"{ind}{keyword} n == {n} then")
        out.extend(list_each(n, ind + T))
        out.append(f"{ind}{T}return")
    out.append(f"{ind}end")
    return "\n".join(out)


def direct_each_chain(indent_level: int) -> str:
    return chain(direct_each, indent_level, wide=True)


SECTIONS = {
    "direct_iterators": lambda level: chain(direct_iterator, level, wide=True),
    "list_iterators": lambda level: chain(list_iterator, level),
    "direct_each": direct_each_chain,
    "list_each": list_each_chain,
}


def main() -> None:
    text = TARGET.read_text(encoding="utf-8")
    for name, build in SECTIONS.items():
        pattern = re.compile(
            rf"(?P<indent>[ \t]*)-- @generated {name} begin\n.*?(?P=indent)-- @generated {name} end\n",
            re.S,
        )
        match = pattern.search(text)
        if not match:
            raise SystemExit(f"markers for section '{name}' not found")
        indent = match.group("indent")
        level = len(indent) // len(T)
        body = build(level)
        replacement = (
            f"{indent}-- @generated {name} begin\n{body}\n{indent}-- @generated {name} end\n"
        )
        text = text[: match.start()] + replacement + text[match.end():]
    TARGET.write_text(text, encoding="utf-8", newline="\n")
    print(f"regenerated {len(SECTIONS)} sections in {TARGET.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
