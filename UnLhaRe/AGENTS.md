# 64bit版 UnLhaRe の作業規約

- このディレクトリは新APIのRust版。親のx86 ABI、stdcall、Windows専用試験の制約は `../UnLha32Re/` のみへ適用する。
- 対象はWindows/macOSのx64/ARM64。Rust toolchainとCargo.lockを使い、32bit対応を追加しない。
- `scripts/build.ps1 -Test`（Windows）または `bash scripts/build.sh --test`（macOS）でfmt、clippy、テスト、Releaseビルドとローカルbundleを確認する。
- クロスOSのcargo checkはネイティブビルド・実行検証と区別する。4環境のネイティブ検証は `../.github/workflows/modern.yml`。
- 公開C ABIを変える場合は `src/ffi.rs`、`include/unlhare.h`、`tests/ffi.rs`、C exampleを照合する。UTF-8、固定幅整数、呼び出し側所有バッファを維持する。
- 既存出力の保持、CRC検査後のファイル公開、Limits、独立呼び出しの状態分離を維持する。
- 設計はルートDESIGN.md、機能・制限・操作はこのREADME.mdを更新する。依存変更では第三者告知・ライセンス全文も更新する。
- バージョン、タグ、配布名、署名・公証、公開前後の確認は `RELEASING.md` を正本とし、4環境のネイティブCIを確認する。クロスOSのcargo checkだけで配布可と判断しない。
- 生成物はartifacts/、中間生成物はbuild/。コミット・公開は明示依頼時のみ。
