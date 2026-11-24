# Roc Solid (rocx) for VS Code

Highlighting for `.rocx` files, the files Roc Solid's pages and components are written in, and
tasks that run `rocx dev` and `rocx check` and show what they report as problems at your `.rocx`
lines.

## Highlighting

A `.rocx` file is Roc with markup in it. Outside markup, the Roc is coloured by the Roc extension's
grammar: this extension depends on that one (`roclang.roc`), and VS Code installs it too. Inside
markup:

- tags: an element's name, and a component's (`<StatusPill>`), coloured as a type;
- attributes in every form rocx accepts: `class:active`, `on:click.prevent`, `style:--size`,
  `checked?=`, `rel??=`, `text!=`, and a bare `required`;
- strings, entities (`&middot;`), fragments (`<>…</>`), and comments (`<!-- … -->` and `{# … }`);
- holes, `{expr}` and `{...expr}` (and the older spelling `{=expr}`), coloured as Roc again, with
  markup inside them too;
- CSS inside `<style>`, by VS Code's own CSS grammar.

Text between tags stays plain.

The one guess the grammar makes is whether a `<` starts markup: it does before a letter, unless a
value is right before it. So `a <b`, a comparison with a space before `<` and none after, is
coloured as markup.

## Problems

There is no language server yet. What the editor shows is what the build says.

**Terminal → Run Task… → rocx** lists two tasks for each app in the workspace (each folder with a
`routes/` folder holding a `+page.rocx`, `+layout.rocx` or `+server.roc`):

- `dev <dir>` runs `rocx dev <dir>` in a terminal of its own. Each time a save builds the app
  again, its problems replace the last build's (until a build ends, the last build's stay).
- `check <dir>` runs `rocx check <dir>` once: the app built from its sources and both of its
  programs type-checked. Its problems stay after it ends, until it runs again.

Problems show at their lines in the editor and in the Problems panel:

- the Roc compiler's errors and warnings, which rocx points into the `.rocx` files;
- rocx's own: a markup mistake, or a warning (about the browser's copy of the app, say).

A problem's text is the report's message, without the quoted line, which the editor shows anyway.

Any other command that prints rocx's reports works the same way, as a task of your own in
`.vscode/tasks.json`. In the rocx repository, for example, `just dev` (the docs site) or
`just check`:

```json
{
	"version": "2.0.0",
	"tasks": [
		{ "type": "rocx", "dir": "examples/hello", "args": ["--port", "8081"], "label": "hello" },
		{ "type": "rocx", "dir": "examples/hello", "check": true, "label": "check hello" },
		{ "type": "rocx", "command": "just dev", "label": "docs site", "isBackground": true },
		{ "type": "rocx", "command": "just check", "label": "check" }
	]
}
```

A task's properties:

- `dir`: the app's folder, relative to the workspace folder;
- `check`: `true` to run `rocx check <dir>` once instead of `rocx dev <dir>`;
- `args`: more arguments for `rocx dev` (`--port`, `8081`; after `--`, the server's own);
- `command`: a command line to run in the workspace folder instead.

A command's problems stay after it ends, until it runs again.

## Settings

- `rocx.path`: the `rocx` to run (`~` is expanded). When it is empty, the extension runs `bin/rocx`
  in the workspace folder if there is one (the rocx repository's own), else `rocx` from your `PATH`.

In a workspace you haven't trusted (VS Code's restricted mode), only highlighting works: the tasks
run the workspace's `rocx`, which builds and runs its code.

## Installing

From a clone of [Roc-Solid/rocx](https://github.com/Roc-Solid/rocx):

```sh
just vscode-extension    # packages editors/vscode into editors/build/rocx.vsix and installs it
```

It needs `code` on your `PATH`, and Node for `vsce`, the packager. Run it again after a pull to
update. Once installed, the extension works in every workspace.
