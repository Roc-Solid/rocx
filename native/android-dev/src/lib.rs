//! The dev client's native library (`libhost.so`, D-063's dev mode): native/android with its `dev`
//! feature (the app's Roc loaded at run time, `Rocx.reload`) and native/core, whose hosted functions
//! and Roc memory functions it exports for the app's library, as Kotlin's JNI functions.
pub use rocx_android;
