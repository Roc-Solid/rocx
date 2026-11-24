# Roc Solid (rocx) for VS Code

Highlighting for `.rocx` files, and what `rocx dev` reports, as problems at your `.rocx` lines.

## Highlighting

`.rocx` files are Roc with markup in them. Outside markup, the Roc is coloured by the Roc extension's
grammar, which this extension needs (`roclang.roc`, installed with it). Inside markup:

- tags (an element's name, and a component's, `<StatusPill>`, coloured as a type), attributes
  (`class:active`, `on:click.prevent`, `style:--size`, `checked?=`, `rel??=`, `text!=`, a bare
  `required`), strings, entities (`&middot;`), `<>…</>`, `<!-- … -->` and `{# … }`;
- holes, `{expr}` and `{...expr}` (and the old `{=expr}`), are Roc again, with markup inside them too;
- text between tags stays plain;
- CSS inside `<style>`, by VS Code's own CSS grammar.

The one guess the grammar makes is whether a `<` starts markup: before a letter, unless a value is
right before it. So `a <b`, a comparison with a space before `<` and none after, is coloured as
markup.

## Problems

There is no language server yet. What the editor shows is what the build says, as it says it.

**Terminal → Run Task… → rocx** lists `dev <dir>` and `check <dir>` for each app in the workspace
(each directory with `routes/` in it). `check` runs `rocx check <dir>` once: the app built from its
sources and both of its programs type-checked, its problems kept after it ends. `dev` runs
`rocx dev <dir>` in a terminal of its own. Each time a save
builds the app again, its problems show at their lines, and in the Problems panel:

- the compiler's errors and warnings, as rocx points them into `.rocx` files;
- rocx's own (a markup mistake, a warning about the browser's copy).

A report's text is its message, without the quoted line, which the editor shows anyway. While a
build runs, the last build's problems stay until it ends.

Any other command that prints rocx's reports works the same way in `.vscode/tasks.json`, such as the
rocx repository's `just dev` (the docs site) or `just check`:

```json
{
	"version": "2.0.0",
	"tasks": [
		{ "type": "rocx", "dir": "examples/hello", "args": ["--port", "8081"], "label": "hello" },
		{ "type": "rocx", "command": "just dev", "label": "docs site", "isBackground": true },
		{ "type": "rocx", "command": "just check", "label": "check" }
	]
}
```

A command's problems stay after it ends, until it runs again.

## Settings

- `rocx.path`: the `rocx` to run. When it is empty, the extension runs `bin/rocx` in the workspace
  folder if there is one (the rocx repository's own), else `rocx` from `PATH`.

## Installing

From a clone of [Roc-Solid/rocx](https://github.com/Roc-Solid/rocx):

```sh
just vscode-extension    # packages editors/vscode into editors/build/rocx.vsix and installs it
```

Run it again after a pull to update. It needs `code` on the `PATH`, and Node for vsce, the
packager. Once installed, the extension works in every workspace.
