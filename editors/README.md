# Editors

| Directory | What |
|---|---|
| `grammars/` | the TextMate grammars every editor here uses, the only copy: `rocx.tmLanguage.json` (markup over Roc) with its language configuration, and copies of the Roc and CSS grammars (with their licences) for editors that don't have them |
| `vscode/` | the VS Code extension: highlighting, and `rocx dev`'s and `rocx check`'s problems at their `.rocx` lines (its README) |
| `orca/` | the Orca plugin: highlighting of `.rocx` and `.roc` files (its README) |
| `check-grammar.cjs` | `just grammar-check`'s: every `.rocx` file tokenized, its markup closed by its end |

```sh
just vscode-extension   # package editors/vscode with the grammar and install it into VS Code
just orca-plugin        # put the Orca plugin together with the grammars and install it into Orca
just grammar-check      # the grammar against every .rocx file, and the VS Code extension's tests
```

An editor's package gets its own copies of the grammars when the recipe puts it together, in
`editors/build/` (ignored by git). That is because neither VS Code nor Orca reads a file outside
the package's own directory.

Zed reads tree-sitter grammars, not TextMate's; see TODO.md.
