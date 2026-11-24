#!/usr/bin/env python3
# A copy of the browser's client (site/build/client → site/build/client-marked, the same depth, so
# its relative paths hold) whose Root.made! puts a marker before each page:
#   PageX => Html.component(|| Html.join([Html.no_hydration([Html.text("rocx-chunk:XPage")]), XPage.view!(…)]))
# The function that refers to the marker string is the page's entry (the level's closure).
# Run from the worktree root after `node site/build.mjs --prepare`.
import re, shutil, sys
src, dst = "site/build/client", "site/build/client-marked"
shutil.rmtree(dst, ignore_errors=True)
shutil.copytree(src, dst)
p = f"{dst}/Generated/Root.roc"
s = open(p).read()
pat = r'(\t\t\tPage\w+ => )Html\.component\(\|\| (\w+)\.view!\(\{ params: \|\| \{\} \}\)\)'
s2, n = re.subn(pat, lambda m: f'{m.group(1)}Html.component(|| Html.join([Html.no_hydration([Html.text("rocx-chunk:{m.group(2)}")]), {m.group(2)}.view!({{ params: || {{}} }})]))', s)
open(p, "w").write(s2)
print(f"marked {n} pages", file=sys.stderr)
