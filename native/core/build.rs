// The crash guard is C (server/host/src/guard.c's): Rust can't call `setjmp`, and a hosted function
// that ends the running computation (a read that waits, a failure) jumps back to its guard.
//
// The fingerprint of the platform an app's library must be built for (`FINGERPRINT`): web/platform's
// header and its hosted functions (main.roc, Host.roc) and the Roc compiler's version, as rocx dev
// computes it for each build (rocx-cli/Dev.roc, `android_fingerprint!`): FNV-1a, 64 bits, in hex,
// of the three joined by NULs. A dev client refuses a library built for another.
use std::path::PathBuf;

fn main() {
    println!("cargo:rerun-if-changed=src/guard.c");
    // In a browser (wasm32) a call into Roc is guarded by the page's JavaScript (a try around it),
    // as web/runtime.js guards one: wasm has no setjmp.
    if std::env::var("CARGO_CFG_TARGET_ARCH").as_deref() != Ok("wasm32") {
        cc::Build::new().file("src/guard.c").opt_level(2).compile("rocx_guard");
    }

    let repo = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap()).join("../..");
    let platform = repo.join("web/platform");
    let read = |name: &str| {
        let path = platform.join(name);
        println!("cargo:rerun-if-changed={}", path.display());
        std::fs::read_to_string(path).unwrap_or_default()
    };
    let (main, host) = (read("main.roc"), read("Host.roc"));
    let active = repo.join(".tools/roc-active");
    println!("cargo:rerun-if-changed={}", active.display());
    println!("cargo:rerun-if-env-changed=ROC");
    let roc = if active.exists() { Some(active) } else { std::env::var("ROC").ok().map(PathBuf::from) };
    let version = roc
        .and_then(|roc| std::process::Command::new(roc).arg("version").output().ok())
        .map(|out| String::from_utf8_lossy(&out.stdout).trim().to_string())
        .unwrap_or_else(|| "unknown".into());
    let joined = [main.as_str(), host.as_str(), version.as_str()].join("\0");
    let mut hash: u64 = 0xcbf29ce484222325;
    for byte in joined.bytes() {
        hash ^= byte as u64;
        hash = hash.wrapping_mul(0x100000001b3);
    }
    println!("cargo:rustc-env=ROCX_FINGERPRINT={hash:x}");
    println!("cargo:rustc-env=ROCX_ROC_VERSION={version}");
}
