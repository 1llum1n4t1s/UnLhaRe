# Q32 mixture 粗粒度 phase 診断契約（2026-10-01）

## 実装前の失敗条件

### 初回実行失敗の是正（実装修正前記録）

初回 root `build/khc-q32-mixture-phase-profile-20261001` の report SHA256 は C1D4B989869E09AE4B3896A224B51D9F8BB6437540602F22167E4299410F9916。正常encode後の Assert-Stats で `GetFullPath: The path is empty`、phase/checksはいずれも0。旧rootのreport/EXE/PDB/frameを保持する。

仮説は PowerShell 自動変数 `$input` と `[string]$Input` 引数の衝突。元スクリプトの関数を読み取り専用AST抽出し、保存済みnormal stdout・固定group・生成frameを使って実関数呼出しで再現してから引数名を改める。再現・修正後のbinding/Parser確認はcodec CLI/buildを実行しない。新規失敗条件は入力pathの束縛消失、Parse-ProfileからAssert-Statsへの受渡し不一致、codec凍結hashの変化。

バグ修正後の親による単一検証だけに、未使用root `build/khc-q32-mixture-phase-profile-20261001-binding-fix` を使う。これはbusy時の自動retryではなく、保存した失敗の原因を修正した後の検証である。compiler/quiet/3run/その他既存条件を維持する。

原因確認: 元関数のAST抽出・保存済みnormal Statsによる実呼出しで同じ `GetFullPath: The path is empty` を再現した。最小binding関数でも `[string]$Input` に渡した値は空、隣接する `[string]$ArchiveInputPath` は渡した値を保持した。PowerShell自動変数との衝突を確認し、Assert-Stats/Parse-Profileの引数を ArchiveInputPath/ArchiveOutputPath に改名する。

修正後の実関数確認では、保存済みnormal stdoutからAssert-Statsを実呼出ししてPASS。保存済みStatsと合成の診断JSON（全10phaseの整数ns）でParse-Profileを実呼出しして、Assert-Statsへのpath受渡しもPASS。合成JSONはbinding確認専用であり実計測の証拠ではない。PowerShell Parserはエラー0。失敗reportへScriptStackTrace/InvocationInfo.PositionMessageを独立fieldで追加し、本文や秘密値を新規に記録しない。

- 凍結 codec/CTS、依存、rustc 1.98.1、通常 candidate、固定入力・frame、正式速度証拠の hash または長さの不一致。
- 入出力祖先の reparse、既存 build root、既存出力への上書き、no-clobber sentinel の変更。
- 元 codec の演算 statement、モデル、確率、bit、wire、CRC、公開方式の変更。per-bit タイマーの挿入。
- fmt 不一致、PowerShell parse エラー、子プロセス非zero/120秒 timeout、quiet-host 旧 threshold 15/preflight 5/全子前後の拒否。
- normal encode 1回または profile encode 3回の frame が固定 frame と全byte一致しない、相互復号の長さ/SHA不一致、整数ns統計欠落。
- source-after hash の変化、想定外一時ファイル、証拠欠落。安全な新規 root を作成した後は failed report を残し、自動 retry しない。

## 所有・凍結

編集対象は causal-bayes-q32-mixture-profile/{codec.rs,profile.ps1} と本契約だけ。凍結 codec SHA256 9D757709834F501B83929C2882BCE6053FCA5CFC5AAEEC2B4A16EED7AE58680B、CTS BBD229E9B8E787618472E66421EF5E38E0BCBBB63B761575032892C3EDBE98E2。CTS は ../causal-bayes-q32-mixture-reuse/cts_model.rs を参照し、他依存の相対参照を保持する。Git、外部、秘密、CPU設定、製品、x86は対象外。

## 境界と算式

std::time::Instant の粗い境界だけを追加し elapsed().as_nanos() の整数を stdout JSON に出す。main_read_ns は read_bounded 前後、main_encode_ns は encode/decode 前後（decodeでは復号全体）、main_publish_ns は publish 前後。encode_bwt_ns は bwt 呼出し前後、encode_payload_ns は encode_payload 呼出し前後、encode_frame_crc_build_ns は payload返却後からframe組立完了まで。

payload_prepare_ns は run列/next/alphabet/active構築、payload_model_allocation_lut_ns は Stream構築全体（range coderとModel/CTS/Bayesのallocation/LUT構築を含む）、payload_entropy_loop_ns は全runループと終端active検査、payload_range_finish_ns は encoder取出しからfinish返却まで。各spanは直前spanのelapsed取得後に開始するためタイマー境界の overhead は親spanに含まれる。子span合計は親spanと厳密一致しない。main合計もCLI全process wallとは異なる。nsの算式は (end - start).as_nanos()。

## 準備・実行

今回の担当は準備・binding是正だけでコンパイル/CLIを実行しない。親review後の単一実行は未使用 build/khc-q32-mixture-phase-profile-20261001-binding-fix を新規確保し、readlock/hashpins、fmt、Parser、native opt3 compile、normal encode×1、profile encode×3、全byte比較、双方decode hash、encode/decode既存出力拒否を確認する。source-after SHAと root inventory を report に残す。

診断3回の局所内訳だけを報告する。instrumented overheadを含むため正式速度判定・採用判断へ絶対使わない。正式条件483599 bytes/<574.5624 msは未達のまま維持する。RAII Drop順によってstream/last等の解放は子span外・親span内に残り得る。loop内のprimary/CTS/Bayes/range個別内訳は未測定。
