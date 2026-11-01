use std::{env, fs, path::PathBuf};
fn main() {
    println!("cargo:rerun-if-env-changed=QRK_EMBED_RUNTIME");
    let out = PathBuf::from(env::var("OUT_DIR").unwrap()).join("embedded_runtime.rs");
    let body = if let Some(path) = env::var_os("QRK_EMBED_RUNTIME") {
        let path = PathBuf::from(path)
            .canonicalize()
            .expect("embedded ONNX Runtime path is invalid");
        println!("cargo:rerun-if-changed={}", path.display());
        format!(
            "pub const EMBEDDED_RUNTIME: Option<&[u8]> = Some(include_bytes!({:?}));",
            path
        )
    } else {
        "pub const EMBEDDED_RUNTIME: Option<&[u8]> = None;".into()
    };
    fs::write(out, body).unwrap();
}
