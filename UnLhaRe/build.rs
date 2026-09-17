fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        // 配布先でも呼び出し元のrpathからライブラリを探索する。
        println!("cargo:rustc-link-arg-cdylib=-Wl,-install_name,@rpath/libunlhare.dylib");
    }
}
