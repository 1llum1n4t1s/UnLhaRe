# SIMD posterior商: 正確さ・容量検証結果

本goal turnはPROGRESS。重いCTS更新の16個のposterior商を4件単位でまとめる別研究候補を実装し、数値oracleとfull codecの対応を外部CLIで確認した。製品コード/公開API/バージョンは今回変更していない。正式速度計測・7-Zip総合超えは未達。旧候補のterminal性能試行は再実行していない。

## 数値proof

- `build/khc-simd-quotient-20261002/report.json`: SHA256 `FE390BBE820107F32570BFC6E416E5FA947743848131F8EB8513BFC4E02E1EDE`、status `batch_numeric_verified_not_codec_or_timing`、32 checks / 87 CLI / 10 identities。
- opt2/opt3、overflow-checks=yes、scalar/AVX2の各条件で9293629件を独立u128直接商oracleと逐次照合。全件一致、2323408 batches、fingerprint `e5c97b90b4768836`。
- 各条件 estimated8274640 / down788744 / up3831 / native125326 / shifted893374 / errors289 / certificate fallback0。14 BigInteger商×4条件、混在lane、tail1/2/3、引数拒否も照合。raw数値列は生成していない。
- helper `simd-quotient/exact_div.rs`: SHA256 `9A135D48AD9C80B02B5BF916301EBBA0F95ED3EA578B6E0B0563A4E6E38645C7`。

## Full codec proof

- `build/khc-causal-simd-quotient-20261002-warning-fix/report.json`: SHA256 `09A9497FC34C580E7D18EFF3F0BCB988439FF40B6221BE77074C354B8D19BE7E`、status `correctness_and_size_passed_not_timed`、47 checks / 83 CLI / 263 identities。
- UTC2026-10-01T18:00:46.2149372Z〜18:01:39.0102402Z。Windows x64、rustc1.98.1 SHA `CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC`、PowerShell7.6.5。AVX2 featureは数値proofで実測true。
- native(auto)/checked(auto)/scalar/checked-scalarの4EXEで7入力の全文frame・encode stdout・全文restoreを旧方式と比較。旧decoderへの/旧frameからの双方向restore、5不正frame出力なし、encode/decode no-clobber、missing input拒否も成功。後者の外部安全検証はnative(auto)で実行した。
- 固定frame483496B、SHA256 `CF62CD2324B4CF889CDDDB25C9508C28E4BD4D24217B93BB7D4FF9318C3EAD12`。固定483599Bサイズゲートを通過。future学習とscheduleを含め本文/stdoutは旧方式と同じ。
- 正規EXE247296B、SHA256 `C54FADC9A17F584EBF6267A337107EB1149F0B3B954EA9F30B409A9AB3BFD948`。checked248832B `FEA545C47C945A658F42AAC4A715A8BCAD862174D3ABC84BB82AED77604D71C5`、scalar245248B `39BF0C18EBE5F06EA3814B3D04A7E3B5A70B5768DA10C005070A23A4EBF6DB3F`、checked-scalar246784B `228A429F91D3F89ECD28D54F087D25B31CD7E52EDF7D26944843A8DE985FDA71`。
- `causal-simd-quotient/correspondence.json`で原4ファイルからの全文明示置換を実行し、`verifier-correspondence.json`でも元verifierからの全文一致を事後確認した。置換済みで未使用になった旧posterior helperは新候補から除去。KT大型分母・alpha・next_weight、Bayes、light、schedulerの世代/poisonの分岐は維持。
- group内の入力拒否をlaneごとのResultへ保持し、leaf→rootの旧更新位置で返す。捏造private Prediction/重複index/破壊状態の内部部分更新同値や全拒否分岐の実測は、この通常状態のE2Eとは区別して未検証。

## 失敗証拠と修復

1. 初回root `build/khc-causal-simd-quotient-20261002`: source copierの末尾改行が1個増え、全文対応で停止。codec/compiler CLIは0件。report SHA `216CEC2605F9860D8F5E208528F0CFE4C7846304EA5AB175ABF741A651291436`。改行追加を明示appendとして対応manifestへ記載し、照合条件は緩めていない。
2. `build/khc-causal-simd-quotient-20261002-correspondence-repair`: 初回compiler exit0だが、置換後未使用のposterior helperにdead_code warning。stderrを拒否して停止、圧縮/展開は0件。report SHA `E98EAFEA726084F247EEF979FB7A108694438988407DA982F300D87DA6E945D3`。unused helperを除去して対応manifestへ記載し、別rootで上記E2Eを完了した。

## 容量節約と終了確認

- 数値root8MiB/full root32MiBの事前・事後guard。単体rustcのみ、新Cargo target/cache/巨大raw traceなし。MSVC linker `/DEBUG:NONE`で後続full4EXEのPDBを生成しない。full rootのPDB0を実測した。
- 数値検証で先に生成されたPDB2件だけを清掃。正確な絶対パス/祖先no-reparse/利用中process0/排他open/未追跡/未参照/hash/lengthを検査し、単一PowerShellでliteralパスを削除。2646016Bを回収。ごみ箱/backupなし、保持source/compilerから再生成可能。詳細は `simd-quotient/pdb-cleanup-{plan,result}.json` と同 `cleanup-pdb.ps1`。
- 清掃後のnumeric355662B / full20216979B / 2失敗root366178B、合計20938819B(約19.97MiB)。実行ファイル、参照されたframe/restore、固定input/proofは保持。容量回収を理由にSHA参照を破壊しない。
- 数値/fullの273 identity recordsを清掃後に再hash/length確認し、2report SHA不変。4root合計83ファイル、PDB/tmp/reparse0、関連rustc/cargo/codec/audit/7zaプロセス0。C空き68494663680Bは観測値であり、空き変動全体を今回の清掃成果としない。
- `git diff --check -- UnLhaRe` exit0。既存dirty製品ファイル、x86版、共有Cargo cache、Git stage/commitには触れていない。

## 次の一手

この新EXE/source/proofを固定した正式性能比較を一度だけ準備する。既存固定CPU15%・483599B・encode median<574.5624ms・warmup1+measured9・3codec circular順・CLI全境界を維持。旧terminal候補の再試行はしない。新性能rootも有限予算を設定し、必要な候補/native証拠だけを残す。高速化の採用は計測後に判断し、今回の数値一致・SIMD利用だけから速度向上を主張しない。holdout/カテゴリ、同境界decode、四native決定性、製品組込み、総合7-Zip超えは引き続き未達。
