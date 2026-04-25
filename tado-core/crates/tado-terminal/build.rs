use std::env;
use std::path::PathBuf;

fn main() {
    let crate_dir = env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR");
    // After the T1 workspace split the terminal crate sits at
    // `tado-core/crates/tado-terminal/`. The canonical header path
    // (consumed by `Sources/CTadoCore`) stays at `tado-core/include/`,
    // so this climbs two directories up before writing. Keeps
    // Package.swift + CTadoCore unchanged.
    let workspace_include = PathBuf::from(&crate_dir)
        .join("..")
        .join("..")
        .join("include");
    let out = workspace_include.join("tado_core.h");
    std::fs::create_dir_all(out.parent().unwrap()).ok();

    cbindgen::Builder::new()
        .with_crate(&crate_dir)
        .with_language(cbindgen::Language::C)
        .with_include_guard("TADO_CORE_H")
        .with_no_includes()
        .with_sys_include("stdint.h")
        .with_sys_include("stddef.h")
        .with_sys_include("stdbool.h")
        .with_parse_deps(false)
        .generate()
        .expect("cbindgen failed")
        .write_to_file(&out);

    println!("cargo:rerun-if-changed=src");
    println!("cargo:rerun-if-changed=Cargo.toml");
}
