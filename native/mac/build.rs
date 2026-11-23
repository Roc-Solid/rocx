// Links the app's Roc, built for the Mac as an archive (web/platform's `arm64mac` target):
// ROCX_APP_ARCHIVE names it. Without it, the runner builds with nothing to run.
fn main() {
    println!("cargo:rerun-if-env-changed=ROCX_APP_ARCHIVE");
    if let Ok(archive) = std::env::var("ROCX_APP_ARCHIVE") {
        println!("cargo:rerun-if-changed={archive}");
        println!("cargo:rustc-link-arg={archive}");
    }
}
