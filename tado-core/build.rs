use std::env;
use std::path::PathBuf;

fn main() {
    let crate_dir = env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR");
    let out = PathBuf::from(&crate_dir).join("include").join("tado_core.h");
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
