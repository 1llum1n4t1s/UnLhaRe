# SA-IS研究基準に対するBayes対数表 — 実装前契約

現研究基準は独立照合済みSA-IS。fixed frame483468B/B4F17DEFF3B39FF26E5DBD38454B51FB1196FFEB1B5252E93E65D5E4B9A3824A、通常9回中央値2543.9207ms、fixed strict574.5624ms未満は未達。log-table単独の数値52 CLI/全codec61 CLIは同値PASSだが性能未測定で、旧exact-div基点の候補を採用済みとは扱わない。今回は現在のSA-IS基準に対する一変数の候補として、既存の検証済みBayes対数表を参照する。旧候補/契約/proofは凍結し、過去の「組合せなし」を遡及編集しない。float CTSは今回preflight2/5/63%で未起動・性能未判定のまま、採用も組合せもしない。

## 所有・最小差分

新 `causal-bayes-sais-log-table/{codec.rs,verify.ps1,compare.ps1,cleanup-*.ps1}`、専用 `build/khc-bwt-causal-bayes-sais-log-table-20260930/`、本契約/開発文書だけを所有する。codecは凍結SA-IS全文から (1) BWTを凍結SA-IS相対参照 (2) Bayesを凍結log-table相対参照 (3) encode/decodeのModel::newへ`?` を付ける、の3種類だけ。CTS/exact_div/primary/context/grammar/packed/range/wire/CRC/decoder/公開処理は不変。Bayes表はstream所有32768 f64、構築をfull CLI wall/peakへ含める。モデルや予測/update順は変えず、signed/floatや他方式を足さない。

先行数値proof `khc-bwt-causal-bayes-log-table-20260930/numeric-e2e/report.json` SHA F09A9C963A823D32FDA1A8943896FA6704CC5175F813623AF1433896806A327A と、同proofが指す全source/input/oracle/保持出力の現在identityを照合し、実Bayes表sourceが凍結E50A6DDFEB93044A7A7DBFAC6881F863DE94E194F3E5EF50A9E8E211D4181422であることを確認する。数値仕様は不変なので同条件の52 CLIを無意味に再実行しない。先行清掃で削除された反復だけはreceiptに照合し、初回/入力/期待値は保持する。

## 先に失敗条件

- 参照module/constructor以外のsource差分、表source/旧SAIS/CTS/exact_div/range/packed/proof pin変更、readlock前の実行は候補無効。
- table確保失敗はResultで伝播。表構築時間/追加256KiBを除いた速度比較、予測前後/update順変更、有限値/範囲検査の削除は許可しない。
- 全frame非同値、new opt3/opt2非同値、全metadata/本文/EOF不一致、CRC修復攻撃の誤受理、既存出力上書き/失敗後公開、上限の弱化は失敗。
- 新root/output/reportはCreateNew、全ancestor非reparse、既存root拒否、子process120秒/自身の子finally解放、全source/binary/input/proofのbefore/after identity保持を維持。
- 新codecの全36 checks/61 CLIを元のfixture・負例・固定groupで実行、new opt3/opt2 cross・反復・全frameを検証する。別担当は変更差分/更新順/全proof/current pins/raw/CRC/metadataを独立read-only照合する。

## 性能と採否

correctness/数値proof/current pins/独立照合後だけ性能へ進む。comparison controlは採用済みSA-IS EXE SHA9AC5CA8F200611454F2AC7E482737518FA90842353F26B750F3A0420E07E7FBAで、旧exact-divを使って一変数比較と称さない。候補/native26.03と同session warmup1+9/circular/39 CLI、全encode wall/child CPU/peak、初回最終復元/metadataを保存する。旧quiet observer読込前lock/preflight5/全子前後15%を維持し、host拒否は失敗/未判定、blind再試行なし。性能workは1sessionを上限にする。

固定group2811006B/SHA18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76、native11件/options/single-thread、総書庫<=483599B/strict全encode<574.5624msは変更しない。正規化比/中央値は9回だけ、途中/診断値を採用証拠としない。決定性はWindows x64/Rust1.98.1/edition2024/opt3・opt2で実検証した範囲だけ。製品/API/version/deps/Git/外部公開/holdoutへの変更、新unit、他process停止、priority/affinity/power/閾値変更は禁止。総合7-Zip超過と局所研究採用を区別する。

独立照合後の不要な中間反復だけを絶対LiteralPath/非reparse/終了process/実SHA/保持初回最終同値確認/receipt付きで清掃する。初回最終/再現入力/証拠/source/binaryは保持、過去policy拒否/cache/UnLha32Re/registry操作なし。I/O/OOM故障注入/他OSの未検証を成功と称さず、元publishのcleanupを万能保証とはしない。
