// The crash guard is C: Rust can't call `setjmp` (it returns twice), and Roc's `roc_crashed` must
// never return, so a crash jumps back to the guard around the call into Roc.
fn main() {
    println!("cargo:rerun-if-changed=src/guard.c");
    cc::Build::new().file("src/guard.c").opt_level(2).compile("rocx_guard");
}
