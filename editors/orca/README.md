# Roc Solid syntax for Orca

Highlighting for `.rocx` files (the files Roc Solid's pages and components are written in) and for
`.roc` files, in [Orca](https://github.com/stablyai/orca)'s editor. It is a plugin of content only:
TextMate grammars, with nothing that runs, so it installs without asking for any access. It shows
no errors, since Orca has no way for a plugin to show them; run `rocx check` for those.

```sh
just orca-plugin      # from the repository's root; again after a pull, to update
```

The recipe puts the plugin together in `editors/build/orca` (this folder's manifest, and the
grammars from `editors/grammars` in `syntaxes/`), validates it, and installs it from there.

## What it colours

- **Roc**: everything outside markup, by the official Roc grammar (roc-lang/roc-vscode).
- **Markup**: tags (an element's name; a component's, `<StatusPill>`, as a type), attributes
  (`class:`, `on:click.prevent`, `style:--size`, `checked?=`, `rel??=`, `text!=`, a bare
  `required`), strings, entities (`&middot;`), `<>…</>`, comments (`<!-- … -->`, `{# … }`) and
  `<!doctype html>`.
- **Holes**: `{expr}` and `{...expr}` (and the older spelling `{=expr}`) are Roc again, with markup
  inside them too (`{...rows.map(|row| <li>{row.name}</li>)}`). Text between tags stays plain.
- **CSS** inside `<style>`, by VS Code's CSS grammar. A `<script>`'s text is left as written.

## The one guess

The grammar decides that `<` starts markup before a letter or `>`, unless a value is right before
it (`a<b`). rocx itself decides by where an expression can begin (the syntax page's "Where < starts
markup"), which a TextMate grammar, reading a line at a time, can't see. So `a <b`, a comparison
with a space before `<` and none after, is the case it colours wrong: as markup, until a `</b>`.
Nothing in this repository writes it that way.

## Checking it

`just grammar-check` tokenizes every `.rocx` file in the repository with VS Code's TextMate engine
(vscode-textmate, installed once into `.tools/grammar`) and fails on any file whose markup is still
open at its end, which is what a wrong guess about `<` leaves behind. It runs the VS Code
extension's tests too.

## Files (in `editors/grammars`)

| File | From |
|---|---|
| `rocx.tmLanguage.json` | this repository (MIT) |
| `rocx.language-configuration.json` | this repository (MIT), after the Roc one |
| `roc.tmLanguage.json` | [roc-lang/roc-vscode](https://github.com/roc-lang/roc-vscode) 0.1.0, as it is (UPL-1.0, `LICENSE-roc.txt`) |
| `roc.language-configuration.json` | roc-lang/roc-vscode 0.1.0, its surrounding pairs written as Orca reads them (UPL-1.0) |
| `css.tmLanguage.json` | [microsoft/vscode-css](https://github.com/microsoft/vscode-css) at c216f77, as converted by Shiki (MIT, `LICENSE-css.txt`) |

Orca colours only the grammars a plugin ships (an include of a scope from elsewhere stays plain),
which is why the plugin carries the Roc and CSS grammars too. The VS Code extension
(`editors/vscode`) takes the rocx grammar alone: VS Code has CSS, and Roc comes from the Roc
extension.
