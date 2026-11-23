// The crash guard is C (server/host/src/guard.c's): Rust can't call `setjmp`, and a hosted function
// that ends the running computation (a read that waits, a failure) jumps back to its guard.
fn main() {
    println!("cargo:rerun-if-changed=src/guard.c");
    cc::Build::new().file("src/guard.c").opt_level(2).compile("rocx_guard");
}
