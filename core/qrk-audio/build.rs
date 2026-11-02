fn main() {
    println!("cargo:rerun-if-changed=src/alsa_quiet.c");
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("linux") {
        cc::Build::new()
            .file("src/alsa_quiet.c")
            .compile("qrk_alsa_quiet");
    }
}
