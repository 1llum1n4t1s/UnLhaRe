# KHC1製品統合：Windows x64実測記録

2026-10-05。製品統合の途中経緯を含む台帳。最終比較・資源・制限・完了判定は[最終結果](product-comparison/RESULT_20261005.md)を参照する。4環境native成功や7-Zip総合優位を意味しない。

## 変更

製品`src/khc/`へ必要なBWT/frontend/grammar/全class paid-static model/packet/integer range/visited逆BWTを独立portし、Rust block/archive APIとCLI khc-create/list/test/extractを接続。src→experiments依存0。32B archive header、bounded manifest、1MiB frame分割、file CRC、end markerを追加し、LHA API/wire/default/package versionは不変。C/.NETの新KHC APIは追加していない。

directory collectorを保持root付き共通helperに抽出し、source identityと型検査・既存staging/no-replaceを再利用した。UTF-8 portable名/case重複/file-child/深さ/entry/total上限をmanifest検査で拒否する。仕様はKHC_FORMAT.md、使い方はREADME、構造はDESIGNへ反映。

## 実行環境とコマンド

AMD Ryzen 5 7640HS / 6core・12logical / Windows x64。rustc 1.98.1、既存Cargo.lockと共有build/cargoを再利用。cargoはPATHになかったため、実体`C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/cargo.exe`、RUSTCも同toolchainの絶対pathを使用した。PATH不在をcode bugとは扱わない。

`cargo check --locked --offline --release --target x86_64-pc-windows-msvc --lib --bin unlhare-cli`成功。clippy初回は14 style lintで失敗し、等価iterator/条件/initializerなどへ修正した。製品lib/binと新6 integration targetの`cargo clippy ... -- -D warnings`は最終成功。

`cargo test --locked --offline --release --target x86_64-pc-windows-msvc --test khc_normal --test khc_adversarial --test khc_block_normal --test khc_block_adversarial -- --test-threads=1`：6test全成功。UNLHARE_KHC_FIXED_INPUTに既存all.groupの絶対pathを指定し、SHA18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76の3blockを使用した。

| 確認 | 実際の結果 |
| --- | --- |
| block正常 | 空/1B/all256/repeat/skew/random/3symbol/境界の9直接往復、oversize拒否 |
| frozen3block | 157149/237852/120312B、計515313B。製品defaultのサイズは修理済み実験frameと一致、各rawを直接byte照合。符号列SHAの全一致までは検証していない |
| ablation入口 | LowHistoryOnlyでも同じdecoderで完全復元。速度/圧縮率効果はまだ比較前 |
| 実CLI | UTF-8 nested/空/極小/all256/複数blockのcreate→list→test→extract成功。APIと照合し、全fileを直接byte比較 |
| block異常 | CRC再封印を含む30件をpublic decoderで拒否、30件の同process正常復号へ回復。実験の独立uniform witness30件とは異なるfixtureである |
| archive異常 | header/manifest/block/file CRC・切断・末尾不正を拒否。失敗entryを未公開、既存出力保持、limits/names/collision/cancel/finalize競合を確認 |

`cargo test --locked --offline --release --target x86_64-pc-windows-msvc --lib --tests -- --test-threads=1`はexit0。既存LHAのroot/beneath reparse・公開・high/LH4・CLI/FFI/JSON等と新KHCを含む回帰成功。Cargo設定test=trueの既存khc_lab exampleも158test成功した。全commandのcompileは3m30s、実行されたcaseの成功とmacOS未実施を区別する。DLL linkerの日本語生成通知warningは出たが、Rust code lint失敗ではない。

## 独立レビューからの修正

独立read-only reviewerは主要20fileを確認し、2件を指摘した。

- paid_model parseの葉ごとの全1024 mask走査を同じ履歴合同類のstep_by列挙へ置換。深さ5の全852rootモデル（363832B）は893386752回のmask照合から、872448の該当slot代入になる。CDF/wireは同じ。最大分割uniform treeを独立fixture encoderで作りpublic decoderへ渡し、1MiB完全復元を55.5243msで確認した（単発の境界診断、速度倍率の実測ではない）。
- macOS entry openへNONBLOCKを追加し、writer不在FIFOで型検査前に待機しない設計へ修正。macOS子process3秒timeoutのAPI E2Eを追加。Windowsでは当該cfgのnative検証は実行されない。macOS実動作は未実施。

最大分割E2Eの初回は、通常encoderのmodelがuniform241Bであるとのfixture前提が外れ246Bで失敗した。製品故障ではなく、学習payloadをuniformモデルへ借用する不正なfixture設計だった。前提を外して成功扱いにせず、独立uniform integer range fixtureを組み直し、有効最大分割frameの完全復元という元の判定を維持して再実行した。

`--test khc_model_boundary --test khc_state_safety`最終2test成功、source交換（同size/mtimeだが別identity）の拒否・未公開、Unix epoch前−0.5秒→−1秒を確認。修正後block異常30/回復30も再成功した。
すべての製品修正と比較helper作成後、全`--lib --tests`回帰を再実行してexit0（compile3m54s）。
固定all.groupを環境変数で指定した製品block往復・最大モデル・source競合・実CLIも再成功した。
`cargo fmt --all --check`と製品lib/bin/新6E2E/khc_block_io exampleのclippy `-D warnings`は最終成功。
git diff --checkは成功。旧研究moduleを読み込むcurrent helper全体の厳格clippyまで成功したとは主張しない。

## 資源と残作業

製品source+source map/失敗契約は123485B時点を確認。最終回帰後shared Cargo baseline5906793080B→6052488570B、今回観測増分145695490Bで256MiB予算内。
専用E2E保持物6315088Bで8MiB内。既存raw/corpusを複製せず、frame診断と比較はRAMのみ。
free34368581632Bを観測し5GiB+予算を維持。他作業のdrive変動を今回増分へ帰属させない。
agentによるfile削除/Git stage/commit/push/公開/version変更はなし。

比較の初回2件は基盤不具合を保存して修正、repair2は650往復成功・read-only verifier成功。
ただし同時buildとの重複があるため速度の根拠に使わず、final1で旧KHC Standardも同roundへ追加して単独測定する。
結果はproduct-comparisonの原report・台帳・検証器を正本とする。
最終比較/ablation・定量報告・全対象型検査は完了し、最終結果へ保存した。macOS/Windows ARM64 nativeは未実施。
新形式の実装完成と7-Zip等への性能優位を分け、未測定の優位は主張しない。
汎用の完全O(1)ストリーミング一覧・認証・solid・C/.NET接続は未提供制限として明記。
