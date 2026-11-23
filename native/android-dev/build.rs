// libhost.so is named so: the app's library rocx dev links needs it by that name (DT_NEEDED), and the
// loader finds it already loaded.
fn main() {
    println!("cargo:rustc-cdylib-link-arg=-Wl,-soname,libhost.so");
}
