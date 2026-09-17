# 第三者ソフトウェアの告知

この近代化版は旧 `UnLha32Re` のC/C++エンジンを組み込まず、Cargo.lockで固定したRust依存関係を使用します。旧版の告知は旧版に引き続き適用されます。

| 主な依存 | 用途 | ライセンス |
| --- | --- | --- |
| delharc 0.8.0 | LHAヘッダー読取・展開 | MIT OR Apache-2.0 |
| oxiarc-lzhuf 0.4.2 | LH5/LH6/LH7圧縮 | Apache-2.0 |
| crc-fast 1.10.0 | 圧縮時のCRC-16/ARC計算 | MIT OR Apache-2.0 |
| cap-primitives / cap-std / cap-tempfile 4.0.3 | ディレクトリ基点のファイル操作・一時領域 | Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT |
| encoding_rs | 旧文字コードの変換 | (Apache-2.0 OR MIT) AND BSD-3-Clause |
| clap | CLI引数 | MIT OR Apache-2.0 |
| serde / serde_json | JSON出力 | MIT OR Apache-2.0 |
| tempfile | 作成書庫の一時ファイル | MIT OR Apache-2.0 |
| thiserror | Rustエラー型 | MIT OR Apache-2.0 |
| rustix 1.1.5 / windows-sys 0.61.2 | OSの既存ファイルを置換しない確定操作 | Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT / MIT OR Apache-2.0 |

正確なバージョン・全依存一覧はCargo.lock、各パッケージの識別とライセンス・著作権表示の原文は同梱の `THIRD_PARTY_LICENSES.txt` を参照してください。依存のライセンス原文に複数の選択肢がある場合、その条件に従って利用します。Rust 1.98.1標準ライブラリの告知原文は同梱の `licensing/COPYRIGHT-library.html` と `licensing/licenses/` にあります。

公開ソース: https://crates.io/crates/delharc / https://crates.io/crates/oxiarc-lzhuf / https://crates.io/crates/crc-fast 。その他のパッケージも同名のcrates.ioページとCargo registryから対応版を取得できます。書庫の比較用に用いる原版UNLHA32.DLLはこの近代化版へ同梱しません。
