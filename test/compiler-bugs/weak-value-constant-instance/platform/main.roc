platform ""
    requires {
        [Model : model] for main : { init : {} -> model, read : model -> U64 }
    }
    exposes []
    packages {}
    provides { "init": init_for_host, "read": read_for_host }
    targets: {
        x64glibc: { inputs: [app], output: Archive },
        arm64glibc: { inputs: [app], output: Archive },
        x64musl: { inputs: [app], output: Archive },
        arm64musl: { inputs: [app], output: Archive },
        x64mac: { inputs: [app], output: Archive },
        arm64mac: { inputs: [app], output: Archive },
        x64win: { inputs: [app], output: Archive },
        arm64win: { inputs: [app], output: Archive },
        x64mingw: { inputs: [app], output: Archive },
        arm64mingw: { inputs: [app], output: Archive },
    }

init_for_host : {} -> Box(Model)
init_for_host = |{}| Box.box((main.init)({}))

read_for_host : Box(Model) -> U64
read_for_host = |model| (main.read)(Box.unbox(model))
