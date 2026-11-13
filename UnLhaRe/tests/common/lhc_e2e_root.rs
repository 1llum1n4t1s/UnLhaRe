use std::{env, fs, path::PathBuf};

// LHC E2E の外部作業ルートを決める。
// - 明示指定（UNLHARE_LHC_E2E_ROOT）があればそれを使い、既存ディレクトリであることだけを要求する。
// - 未指定なら各OSの既定一時フォルダー（std::env::temp_dir()）配下の UnLhaRe/lhc-e2e を使う。
//   Windows でストレージラッパー経由で実行した場合は TEMP がtask専用tempへ差し替えられているため、
//   その配下に作られる。以前は特定ドライブ配下以外を拒否していたが、その運用は廃止した。
// - どの場合もリポジトリ内と Codex ユーザーディレクトリ（~/.codex）内は拒否する。
//   テストデータが成果物やエージェント設定に混入しないようにするための安全策で、保存場所の方針とは独立に残す。
pub fn path(tag: &str) -> PathBuf {
    let supplied = env::var_os("UNLHARE_LHC_E2E_ROOT");
    let mut base = if let Some(path) = &supplied {
        PathBuf::from(path)
    } else {
        // 一時フォルダー直下へ散らからないよう、全OS共通でリポジトリ名の専用サブフォルダーへまとめる。
        env::temp_dir().join("UnLhaRe").join("lhc-e2e")
    };

    if supplied.is_some() {
        assert!(base.is_dir(), "external LHC E2E root must already exist");
    } else {
        fs::create_dir_all(&base).expect("create external LHC E2E root");
    }
    base = base
        .canonicalize()
        .expect("canonicalize external LHC E2E root");

    let repository = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("repository root")
        .canonicalize()
        .expect("canonicalize repository root");
    assert!(
        !base.starts_with(repository),
        "LHC E2E root must be outside the repository"
    );

    let profile = env::var_os("USERPROFILE")
        .or_else(|| env::var_os("HOME"))
        .expect("user profile");
    let codex = PathBuf::from(profile).join(".codex");
    if codex.exists() {
        assert!(
            !base.starts_with(codex.canonicalize().expect("canonicalize Codex directory")),
            "LHC E2E root must be outside the Codex user directory"
        );
    }

    // 同一ルートを複数プロセスが共有しても衝突しないよう、tag とプロセスIDで専用パスを切る。
    let root = base.join(format!("{tag}-{}", std::process::id()));
    assert!(
        !root.exists(),
        "dedicated unused LHC E2E path: {}",
        root.display()
    );
    root
}
