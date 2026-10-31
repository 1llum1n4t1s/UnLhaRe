# direct-token full codec: 実装・実行前契約

前段はPROGRESS。rangeとCDFの独立数値/状態CLIはWindows x64の4コンパイル条件で成功した。次は `DIRECT_TOKEN_CONTRACT_20261002.md` の新研究magic `KHNTOK01`、next-use rank/run length、整数CDFを完全frameへ接続する。旧binary expert schedulingはこの候補の通常経路に含めない。既存の製品API/level0/4/5/6/7、旧formatと全測定済み候補は編集しない。

## 固定した仕様・事前に想定する失敗

1. rank alphabet257/key=symbol*4+min(previous rank,3)。length alphabet256/key=symbol*9+floor(log2(rank+1))。run完了後のみprevious rankを更新。CDF K4、root初期各1/local0、16384 rescale、legal count truncationはprimitive仕様のまま。encoderとdecoderが違う文脈・更新順になる、残りlengthでtruncateしない、rankをMTFと誤解する、escapeが255/256でずれることを失敗条件に含める。
2. length1..255 token0..254、256以上 token255とcanonical LEB128(length−256)。uniform byteは(cumulative=byte,frequency=1,total=256)。最多4 byte、最終group0の冗長表現、4byte continuation、remaining超過を拒否する。rank範囲、active early exhaustion/end残存、non-maximal adjacent run、sentinel/primary/LF cycleを拒否する。Runはu16/u32/u32の12byte、run件数を先に数えbounded reserveする。input8MiB+sentinelを上限としてchecked長さ・割当を維持する。
3. 凍結BWT/packed alphabet/inverse BWT/CRC/no-clobber CLIの既存実装を再利用。header36byte LE、canonical metadata、plain/payload/header CRCを維持し、CRC/grammar検証が終わるまで出力をcreateしない。payload上限8*n+32、frame上限(8*(MAX_INPUT+1)+32)+281。total<=81920/positive frequencyから各multi-symbol normalize<=3byte、uniform byte<=1byte。run length<256は高々6byte、escape run>=256は高々10byteで、flush5も8*n+32に収まる。bounded reserveとtry_reserveを使い、allocation実失敗注入は未検証とする。
4. forged grammarはcodec encoderを使わず独立literal interval列をprimitive rangeで符号化する。空入力有効frame、noncanonical/unterminated/out-of-range escape、active早期終了/残存、range rounding gap/terminal/trailing、header field/CRC/metadata/payload/plain CRC、短いframe、旧magic、新magicを旧decoderへ渡す拒否を確認。repair CRCの異常frameでCRCだけではなく意図したgrammar errorをstderrへ照合する。
5. 7入力はempty、single byte、全256byte値2周、zero-repeat131072、alternating4096、seeded random4096、固定all.group2811006byte（SHA18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76）。各条件opt2/3×overflow yes/noで全byte復元。4条件frameは同サイズ/hashだけでなく64KiB blockで実byte比較してから不要な一時出力を削除。no-clobber encode/decode、missing input/invalid operation/args拒否後の出力不在または既存保持を確認。旧frame/new decoder拒否とnew frame/旧balanced decoder拒否は実行する。
6. 初期候補の完全frameサイズを483599byteに照合する。サイズ不合格は正確性E2E失敗へ混ぜずsize_gate=falseと記録し、正式性能測定へ進まない。正式gateは単一thread全CLI encode median574.5624ms未満、CPU15%、warmup1+9×3codecの従来固定境界を変更しない。本実行のelapsedは診断だけで、中央値や7-Zip超えの証拠ではない。過去terminal候補/未許可observer変更を再実行しない。

## 容量・証拠・所有境界

- fresh生成先 `build/khc-direct-token-full-20261002`、64MiB上限/空き5GiB+予算。通常見込みは4小codec EXE、1小forge EXE、7つのreference frameとJSONで3MiB程度。一時入力は131072+4096+4096+512+1 byte、固定入力は再利用。最悪payload boundから固定入力frame2個約44.98MiB+restore2.81MiB+小fixture/EXE/reportでも64MiB内。順に処理し、過去のframe・入力を複製しない。
- source editsはapply_patch。生成fixture/report以外のshell書込みをしない。PDB、Cargo/cache、raw trace、巨大列は作らない。各CLI120秒/stdout stderr65536文字、report512KiB以下。parent・workerとも同一出力先へ並列実行しない。
- 親は `direct-token/codec.rs` と契約/結果文書、workerは `direct-token/verify-full.ps1`、`frame_cases.rs`、`FULL_FAILURE_PLAN.md`、指定full root内の生成物を所有。workerは親のsource freeze/hash通知までcompile/runしない。source/guard/contract/primitive report/compiler/inputsのidentityを前後記録し、可能なsourceは読み取り共有lock。実byte比較とcleanupの事実をtransient_path/hash/bytes/比較byte数の台帳へ保存し、削除済み一時物を現存証拠と混同しない。
- immutable primitive report SHA: range `3C15411EEA53B6F9E401BC4A0C692629F9B53140E56963F362FE3DC0851B95AE`、CDF `A3670F506550B6DA89878B840E7DCB63C770A5FD2F2BAFF3EC1CE19517FB3632`。range/CDF sourceはそれぞれ `CAEEA3C1CD6BCD26A45BFEDC4EAF1A825C4A6860E0958E2FEA1C9EAA403F8129`/`2F8308785D64BD65004A09529F76CC69E98E9DDA781BFCFB86BC76ADB8139E53`。BWT `810662D4168EE8AC00C81A446D1F3B17056DBBEAFAD1724C43AB0C74A546132F`、packed `4934593F891296B72F91F8FB2CC27D26262514B3B153319A8EC1CDCA64B2734D`。Rust1.98.1 compiler SHA `CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC`。
- 親source修正/検証失敗時は原因と再現最小限を残し、同条件の自動再試行/既存root上書きはしない。安全に直せるコード原因は新version契約とfresh rootで是正する。性能不合格を評価条件変更で回避しない。
- cleanupは今回のexact owned pathのみ。祖先/対象non-reparse、child終了、全比較/read handle閉鎖、他作業混在なしを確認して単一PowerShellセッションでRemove-Item -LiteralPath。input・必要proof・旧root・共有cache・x86版は削除しない。Git stage/commit/push、version、公開、外部書込みなし。追加委任なし。
- full objectiveはサイズとencode/decode速度、holdout/カテゴリ、4 native、製品/API安全性・統合を含む。今回のfull E2Eだけで7-Zip総合超えを主張せずgoal activeを維持する。
