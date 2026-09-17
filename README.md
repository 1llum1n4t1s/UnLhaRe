# UnLhaRe

UnLhaRe はLHA書庫を扱うライブラリです。Windows/macOSのx64/ARM64向けRust版と、既存Windowsアプリ向けx86互換版を分けて提供します。

- **[近代化版 UnLhaRe 1.0.0](UnLhaRe/README.md)**: Rust 1.98.1 / edition 2024、新しいUTF-8 C APIとRust API、CLI。32bitを対象外とし、一覧・検査・展開・新規作成を提供します。[専用リリースページ](https://github.com/1llum1n4t1s/UnLhaRe/releases/tag/unlhare-v1.0.0)から対象OS・CPUのパッケージを選択してください。
- **[互換版 UnLha32Re](UnLha32Re/README.md)**: UNLHA32.DLL 3.00.0.5の32bit ABI互換を目指すWindows DLL。以下の配布案内は互換版のものです。

配布バージョンは **1.0.0** です。DLL の互換バージョン `3.00.0.5` は、既存アプリとの互換性のため配布バージョンとは独立して維持します。

- LZH 書庫の圧縮・展開・一覧表示、メモリ操作、書庫の結合・改名・注釈編集に対応します。
- 使用する DLL は `UNLHA32RE.DLL` です。従来名を固定して読み込むアプリでは、配置時に `UNLHA32.DLL` へ名前を変更できます。32 ビットのホストアプリが対象です。
- 完全互換は開発目標であり、全入力・全副作用の一致を保証するものではありません。[互換範囲・データ保護上の例外・既知の差異](UnLha32Re/README.md) を確認してください。

## 配布物の使い方

GitHub Releases の `UnLha32Re-win-x86.zip` を展開し、`bin/UNLHA32RE.DLL` を対象となる 32 ビットアプリの実行ファイルと同じフォルダーへ配置してください。従来名を固定して読み込むアプリでは `UNLHA32.DLL` へ名前を変更します。システム全体へ影響するため、`System32` や `SysWOW64` には配置しないでください。

配布 ZIP には、再配布条件を満たすため、対応するソース、ライセンス、第三者告知を収録しています。ZIP 内の `README.txt` と `THIRD_PARTY_NOTICES.md` も確認してください。

ソースからのビルドと検証は [開発作業規約](AGENTS.md)、実装構造は [設計文書](DESIGN.md) を参照してください。
署名済み ZIP を準備する短時間チェックと公開の手順は [リリース手順](UnLha32Re/docs/releasing.md) に記載しています。

共通ライセンスは [LICENSE](LICENSE)、完全互換版の第三者ライセンスは [THIRD_PARTY_NOTICES.md](UnLha32Re/THIRD_PARTY_NOTICES.md) を参照してください。
