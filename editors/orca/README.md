# Roc Solid syntax for Orca

Highlighting for `.rocx` files, and for `.roc` files, in [Orca](https://github.com/stablyai/orca)'s
editor. It is an Orca plugin of content only (TextMate grammars, nothing runs), so it installs
without asking for any access:

```sh
just orca-plugin      # from the repository's root, again after a pull
```

The recipe puts the plugin together in `editors/build/orca` (this directory's manifest, and the
grammars from `editors/grammars`, into `syntaxes/`) and installs it from there.

## What it colours

- **Roc**: everything outside markup, by the official Roc grammar (roc-lang/roc-vscode).
- **Markup**: tags (an element's name, a component's `<StatusPill>` as a type), attributes (`class:`,
  `on:click.prevent`, `style:--size`, `checked?=`, `rel??=`, `text!=`, a bare `required`), strings,
  entities (`&middot;`), `<>…</>`, `<!-- … -->`, `{# … }` and `<!doctype html>`.
- **Holes**: `{expr}`, `{=expr}` and `{...expr}` are Roc again, markup inside them too
  (`{...rows.map(|row| <li>{row.name}</li>)}`). Text between tags stays plain.
- **CSS** inside `<style>`, by VS Code's CSS grammar; a `<script>`'s text is left as written.

## The one guess

`<` starts markup before a letter or `>` unless a value is right before it (`a<b`). rocx itself
decides by where an expression can begin (README, Syntax), which a TextMate grammar, reading a line
at a time, can't see. So `a <b`, a comparison with a space before `<` and none after, is the case it
colours wrong (as markup, until a `</b>`). Nothing in this repository writes it that way.

## Checking it

`just grammar-check` tokenizes every `.rocx` file in the repository with VS Code's TextMate engine
(vscode-textmate, installed once into `.tools/grammar`) and fails on any whose markup is still open
at its end: what a wrong guess about `<` leaves behind.

## Files (in `editors/grammars`)

| File | From |
|---|---|
| `rocx.tmLanguage.json` | this repository (MIT) |
| `rocx.language-configuration.json` | this repository (MIT), after the Roc one |
| `roc.tmLanguage.json` | [roc-lang/roc-vscode](https://github.com/roc-lang/roc-vscode) 0.1.0, as it is (UPL-1.0, `LICENSE-roc.txt`) |
| `roc.language-configuration.json` | roc-lang/roc-vscode 0.1.0, its surrounding pairs written as Orca reads them (UPL-1.0) |
| `css.tmLanguage.json` | [microsoft/vscode-css](https://github.com/microsoft/vscode-css) at c216f77, as converted by Shiki (MIT, `LICENSE-css.txt`) |

Orca colours only grammars a plugin ships (an include of a scope from elsewhere stays plain), which
is why the plugin carries the Roc and CSS grammars too. The VS Code extension (`editors/vscode`)
takes the rocx grammar alone: VS Code has CSS, and Roc comes from the Roc extension.
