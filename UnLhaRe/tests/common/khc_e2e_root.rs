use std::{
    env, fs,
    path::{Path, PathBuf},
};

fn is_under_d_codex(path: &Path) -> bool {
    let value = path
        .to_string_lossy()
        .replace('/', "\\")
        .to_ascii_lowercase();
    value
        .strip_prefix("\\\\?\\")
        .unwrap_or(&value)
        .starts_with("d:\\codex\\")
}

pub fn path(tag: &str) -> PathBuf {
    let supplied = env::var_os("UNLHARE_KHC_E2E_ROOT");
    let mut base = if let Some(path) = &supplied {
        PathBuf::from(path)
    } else {
        let temp = env::temp_dir();
        if cfg!(windows) && env::var_os("CI").is_none() {
            assert!(
                is_under_d_codex(&temp),
                "run KHC E2E through the storage wrapper so TEMP is inside D:\\Codex"
            );
        }
        if cfg!(windows) {
            temp
        } else {
            temp.join("Codex").join("UnLhaRe").join("khc-e2e")
        }
    };

    if supplied.is_some() {
        assert!(base.is_dir(), "external KHC E2E root must already exist");
    } else {
        fs::create_dir_all(&base).expect("create external KHC E2E root");
    }
    base = base
        .canonicalize()
        .expect("canonicalize external KHC E2E root");

    if cfg!(windows) && env::var_os("CI").is_none() {
        assert!(
            is_under_d_codex(&base),
            "local Windows KHC E2E data must stay under D:\\Codex"
        );
    }

    let repository = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("repository root")
        .canonicalize()
        .expect("canonicalize repository root");
    assert!(
        !base.starts_with(repository),
        "KHC E2E root must be outside the repository"
    );

    let profile = env::var_os("USERPROFILE")
        .or_else(|| env::var_os("HOME"))
        .expect("user profile");
    let codex = PathBuf::from(profile).join(".codex");
    if codex.exists() {
        assert!(
            !base.starts_with(codex.canonicalize().expect("canonicalize Codex directory")),
            "KHC E2E root must be outside the Codex user directory"
        );
    }

    let root = base.join(format!("{tag}-{}", std::process::id()));
    assert!(
        !root.exists(),
        "dedicated unused KHC E2E path: {}",
        root.display()
    );
    root
}
