// The glue's helpers that need std (its default allocators and handlers) are left out: the host is
// no_std, and has its own.
fn main() {
    println!("cargo::rustc-check-cfg=cfg(no_roc_std_helpers)");
    println!("cargo::rustc-cfg=no_roc_std_helpers");
}
