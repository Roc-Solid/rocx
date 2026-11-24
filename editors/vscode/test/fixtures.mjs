// What `rocx check` printed for examples/hello with an unused variable and a number where text
// belongs (rocx dev prints the same reports, each build's).
export const checked = `── ● unused variable ──────────────────────────────── routes/+page.rocx:7:2

Variable unused is defined here and then never used.

unused = 5
^^^^^^

If you don't need this variable, prefix it with an underscore like _unused to
suppress this warning.

── ✗ type mismatch ──────────────────────────────── routes/+page.rocx:11:4

The first argument being passed to this function has the wrong type.

Clicked {count!()} times
^^

This argument has the type:

    () => I64

But the function needs the first argument to be:

    () => Str

── 1 error and 1 warning ────────────────────────────────────────────── main.roc
`;

// What `rocx dev app` printed for the same app: the server's build failing (its count before its
// reports, the paths relative to where rocx dev runs).
export const devFailed = `1 error and 1 warning found in 666ms while successfully building:

    app/build/server.building
── ● unused variable ────────────── app/routes/+page.rocx:7:2

Variable unused is defined here and then never used.

unused = 5
^^^^^^

If you don't need this variable, prefix it with an underscore like _unused to
suppress this warning.

── ✗ type mismatch ────────────── app/routes/+page.rocx:11:4

The first argument being passed to this function has the wrong type.

Clicked {count!()} times
^^

This argument has the type:

    () => I64

But the function needs the first argument to be:

    () => Str
rocx dev: the server's build failed; fix it and save again
`;
