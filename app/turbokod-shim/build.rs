// Compile ``src/tk_vt.c`` (the flat C ABI over libghostty-vt) and bundle it,
// together with libghostty-vt itself, into ``libturbokod_shim.a``.
//
// A Rust staticlib carries its ``static=`` native libraries inside the
// archive, so every Mojo link line that already takes the shim gets the
// terminal emulator with no change. ``scripts/build_ghostty.sh`` must have
// produced ``.build/ghostty`` first — ``ensure_shim`` in ``scripts/lib.sh``
// runs it before cargo.

use std::path::PathBuf;

fn main() {
    let manifest = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap());
    let ghostty = manifest.join("../../.build/ghostty");
    let lib = ghostty.join("lib/libghostty-vt.a");
    if !lib.exists() {
        panic!(
            "{} is missing — run scripts/build_ghostty.sh first",
            lib.display()
        );
    }

    // Without a deployment target, cc compiles for the SDK's own macOS
    // version (26.x), and every Mojo link (which targets an older macOS)
    // warns about the newer object. Rust's own objects default to 11.0.
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos")
        && std::env::var_os("MACOSX_DEPLOYMENT_TARGET").is_none()
    {
        std::env::set_var("MACOSX_DEPLOYMENT_TARGET", "13.0");
    }

    cc::Build::new()
        .file("src/tk_vt.c")
        .include(ghostty.join("include"))
        // The static-library flavor of the headers (no dllimport dance).
        .define("GHOSTTY_STATIC", None)
        .opt_level(2)
        .warnings(true)
        .compile("tk_vt");

    println!(
        "cargo:rustc-link-search=native={}",
        ghostty.join("lib").display()
    );
    println!("cargo:rustc-link-lib=static=ghostty-vt");
    println!("cargo:rerun-if-changed=src/tk_vt.c");
    println!("cargo:rerun-if-changed={}", lib.display());
}
