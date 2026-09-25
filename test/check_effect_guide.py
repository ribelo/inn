"""The Effect guide (docs/guides/effect.md) imports names from the "effect"
package. This check requires every imported name to exist in the typings the
Effect project actually installs, so the guide cannot name a module member that
is not there.

It needs a checkout with node_modules -- EFFECT_PIE_DIR, default
~/projects/ribelo/effect-pie -- and verifies the guide text against
node_modules/effect/dist. Without such a checkout the check is skipped, so the
suite still passes on a machine that has no Effect project; run it with
--verbose to see what was verified.
"""
import os
import re
import sys

repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
guide = os.path.join(repo, "docs", "guides", "effect.md")
checkout = os.environ.get(
    "EFFECT_PIE_DIR", os.path.expanduser("~/projects/ribelo/effect-pie")
)
dist = os.path.join(checkout, "node_modules", "effect", "dist")
verbose = "--verbose" in sys.argv[1:]

if not os.path.isdir(dist):
    if verbose:
        print("effect guide imports not checked: no effect typings under %s" % dist)
    sys.exit(0)

with open(guide, encoding="utf-8") as handle:
    text = handle.read()

imports = re.findall(r'import\s*\{([^}]*)\}\s*from\s*"([^"]+)"', text)
assert imports, "the Effect guide has no import statements to check"

problems = []
checked = []
for names, module in imports:
    if not (module == "effect" or module.startswith("effect/")):
        # A relative import of the reader's own module, not an Effect one.
        continue
    relative = module.split("/")[1:]
    typing = os.path.join(dist, *relative, "index.d.ts")
    if not os.path.exists(typing):
        problems.append("%s: no typings at %s" % (module, typing))
        continue
    with open(typing, encoding="utf-8") as handle:
        declarations = handle.read()
    for name in (part.strip() for part in names.split(",")):
        if not name:
            continue
        patterns = (
            r"export \* as %s from" % re.escape(name),
            r"export declare (?:const|class|function|let|var) %s\b" % re.escape(name),
            r"export \{[^}]*\b%s\b[^}]*\}" % re.escape(name),
        )
        if any(re.search(pattern, declarations) for pattern in patterns):
            checked.append("%s.%s" % (module, name))
        else:
            problems.append("%s.%s is not exported by %s" % (module, name, typing))

assert not problems, "the Effect guide names missing runtime members:\n" + "\n".join(problems)
if verbose:
    print("effect guide imports verified: " + ", ".join(checked))
