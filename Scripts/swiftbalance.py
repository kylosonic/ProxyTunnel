"""Strip Swift comments and string literals, then check bracket balance.

A cheap structural sanity check for contributors who, like this project's CI
set-up assumes, have no Swift compiler to hand before pushing. It is **not** a
parser and it is **not** part of the build: it has known false positives, because
Swift's interpolated strings and raw strings can nest in ways this scanner only
approximates. Treat a mismatch as "look at this file", not as "this file is
broken". `EntitlementInspector.swift` is a standing example — it is fine and the
script disagrees.

Usage:
    python Scripts/swiftbalance.py <file.swift> [...]
"""

import re
import sys


def strip_swift(src: str) -> str:
    out = []
    i = 0
    n = len(src)
    while i < n:
        c = src[i]

        # Raw string: #"..."# or ##"..."##
        if c == "#":
            m = re.match(r'#+"', src[i:])
            if m:
                quote = m.group(0)
                terminator = '"' + "#" * (len(quote) - 1)
                end = src.find(terminator, i + len(quote))
                end = n if end == -1 else end + len(terminator)
                out.append(" " * (end - i))
                i = end
                continue

        # Line comment
        if src.startswith("//", i):
            end = src.find("\n", i)
            end = n if end == -1 else end
            out.append(" " * (end - i))
            i = end
            continue

        # Block comment (nesting, because Swift allows it)
        if src.startswith("/*", i):
            depth = 1
            j = i + 2
            while j < n and depth:
                if src.startswith("/*", j):
                    depth += 1
                    j += 2
                elif src.startswith("*/", j):
                    depth -= 1
                    j += 2
                else:
                    j += 1
            out.append(" " * (j - i))
            i = j
            continue

        # Triple-quoted string
        if src.startswith('"""', i):
            end = src.find('"""', i + 3)
            end = n if end == -1 else end + 3
            out.append(" " * (end - i))
            i = end
            continue

        # Ordinary string literal, honouring \" and \( … )
        if c == '"':
            j = i + 1
            interpolation_depth = 0
            while j < n:
                if src[j] == "\\":
                    if src.startswith("\\(", j):
                        interpolation_depth += 1
                        j += 2
                        continue
                    j += 2
                    continue
                if src[j] == ")" and interpolation_depth:
                    interpolation_depth -= 1
                    j += 1
                    continue
                if src[j] == '"' and interpolation_depth == 0:
                    j += 1
                    break
                j += 1
            out.append(" " * (j - i))
            i = j
            continue

        out.append(c)
        i += 1
    return "".join(out)


def check(path: str) -> bool:
    src = open(path, encoding="utf-8").read()
    code = strip_swift(src)
    pairs = [("{", "}"), ("(", ")"), ("[", "]")]
    ok = True
    parts = []
    for opener, closer in pairs:
        a, b = code.count(opener), code.count(closer)
        parts.append(f"{opener}{closer} {a}/{b}")
        if a != b:
            ok = False
    print(f"{path.split('/')[-1].split(chr(92))[-1]:34} {'  '.join(parts)}  {'OK' if ok else '*** MISMATCH ***'}")
    return ok


if __name__ == "__main__":
    paths = sys.argv[1:]
    if not paths:
        print("usage: swiftbalance.py <files...>", file=sys.stderr)
        sys.exit(2)
    # Evaluate every file: `all(...)` over a generator would stop at the first
    # failure, which is exactly when you want the rest of the list.
    results = [check(p) for p in paths]
    sys.exit(0 if all(results) else 1)
