fn main() {
    let directory = std::path::PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap());
    let config = cbindgen::Config {
        language: cbindgen::Language::C,
        include_guard: Some("QRK_H".into()),
        cpp_compat: true,
        documentation: true,
        ..Default::default()
    };
    // Generate inside OUT_DIR so builds never mutate the source tree.
    cbindgen::Builder::new()
        .with_src(directory.join("src/lib.rs"))
        .with_config(config)
        .generate()
        .expect("C header generation failed")
        .write_to_file(std::path::PathBuf::from(std::env::var("OUT_DIR").unwrap()).join("qrk.h"));
    println!("cargo:rerun-if-changed=src/lib.rs");
}
