# private整数CTS frame: コード前失敗計画

正本 B813A1D3B41F40B615FA356411D0E1F923FA924231ADAC1FF9CB71BBD54122B1。旧source/proof/root凍結。新5fileだけ編集する。compile/runは親の最終確認まで禁止、one opt2/overflowyes、未知失敗後retry/条件変更なし。ユニットテストを後付けせず以下standalone RAM/CLI E2Eを実装する。

## 起こり得る失敗と固定観測

- 未来child漏れ、full区間class/nodeID/prefix/forced1誤り、未知token decodeの経路漏れ: child-free snapshot/CDF→slot child探索、forcedも通常range interval、旧kernel importのみ。
- rank context/active list/next-use/length/escape後historyの更新時期、count/hash/rescale誤り: 固定入力encode/decodeの枝数/class/grammar/base+pool digest/CDF entropyを前proof照合し、全復元byte比較と全frame再符号化比較。
- stale/改変snapshot/cap/非法入力の部分commit: 準備→CTS.observe→非fallible commit。拒否前後に全base count+cachedtotal、全weight、全CTS node raw+weight/history/observations、serial/branch/prefix/rescale/cold/entropy集計を直接比較する。hashのみを証明にしない。
- range丸め/gap/slot/正頻度/消費/flush、escape 256時0byte欠落/非正準/4byte継続/残量超過: 下記forged正常CRC frameを正常guardに通す。escapeはpool/CTSを更新しない。
- header/metadata境界/CRC/packed width/rank/sentinel/padding/LF cycle/primary誤り: 下記30件にtarget理由を固定し、CRC修復する。codec guard無効化は禁止。
- quota/overflow/割当失敗/CAP、CLI no-clobber/部分公開/出力親不足: input8MiBかつCAP3825340・payload min(32*n+6,1MiB)・frame1MiB+281。一般8MiB入力全対応とは主張しない。全成功後create_newし、自作partialだけ清掃。
- graph/pins/環境/容量/timeout/streamcap/失敗証拠漏れ: 9source8edge、readlock/hash前後、EXE_before/child/parsed/frame identity/全byte comparisonをvalidator前永続化。child120秒・UTF8各65536B、失敗bounded partial保存。8MiB root。explicit temporary台帳と安全削除。

## RAM正常14件

empty、constant0長1/2/255/256/257/383/384/16639/16640、全byte0..255を4反復(1024B)、疎alphabet64B(繰返し[0,3,127,255])、LCG4096B(seed0x6d2b79f5、state=state*1664525+1013904223 wrapping u32、上位8bit)、固定ASCII text `Kagayoi private integer CTS frame.\n` を128反復。各入力→encode→decode全byte→reencode全frame比較。normal14/roundtrip14/canonical14。

## RAM異常30件: 名→期待拒否

| 名 | target理由（必要なCRC/metadata/lengthを再作成） |
|---|---|
| short_header | bad frame magic/header |
| old_magic | bad frame magic/header |
| bad_magic | bad frame magic/header |
| input_length | frame fields outside bounds |
| primary_field | frame fields outside bounds |
| alphabet_zero | frame fields outside bounds |
| alphabet_over | frame fields outside bounds |
| payload_short | frame fields outside bounds (payload4) |
| payload_quota | frame fields outside bounds (1MiB+1) |
| payload_derived_bound | payload exceeds transformed bound |
| header_crc | header CRC mismatch |
| payload_crc | payload CRC mismatch |
| plain_crc | plain length/CRC mismatch |
| metadata_padding | packed alphabet high bitmap padding nonzero |
| metadata_sentinel | packed alphabet sentinel 0 missing |
| metadata_width | packed alphabet rank byte width not canonical |
| metadata_rank | packed alphabet rank outside factorial |
| range_prefix | invalid range prefix |
| range_gap | range rounding gap |
| range_truncated | truncated range stream |
| range_trailing | trailing range bytes |
| range_termination | noncanonical range termination |
| sentinel_count | sentinel count |
| primary_sentinel | invalid primary sentinel |
| lf_cycle | LF cycle inconsistent |
| active_early | active list exhausted before declared length |
| active_remaining | active list not empty at end |
| escape_noncanonical | noncanonical length escape |
| escape_fourbytes | length escape exceeds four bytes |
| escape_remaining | run length outside remaining bound |

## Model拒否固定14件＋CAP exact成功1件

prefix0、prefix5、component2、context9、node超過、symbol257、child>=prefix、stale serial、modified CTS derived mixed vector、modified row ID、weight>2Q、zero count、count total>32768、CAP over。CAP exactはclass/node CAP-1 seed後1更新成功→CAP到達拒否を第14拒否のCAPケース内で直接比較する。CAP+1 predict拒否も同ケース内に含め、model rejection assertions16・named cases14・cap exact successes1を固定する。seedはprimitive_audit限定、frame_audit内の自己完結診断にのみ使う。

## CLI固定10件・temporary

zero encode/decode2成功、sentinel16B既存出力へのencode/decode2拒否、missing encode source/decode source2拒否、missing encode parent/decode parent2拒否、unknown operation/引数不足2拒否。成功と拒否後の出力不在/既存全16byte不変を直接観測する。固定入力encode/decode/canonical3操作も別途一回だけ。temporary絶対path/用途/削除条件/使用中とリンクと混在チェック/削除結果をreportに記録。用途終了のrestore2811006Bとtiny fixture<=2KiBのみ削除、EXE/frame/report保持。失敗時も最小証拠と保持理由を保存。

未検証: heap/write/sync fault injection、一般handle-safe抽出、正式speed/CPU/holdout/4native/product、任意pure-helper改変に対する公開API保証。size gateだけで全goal達成としない。full benchmark常時禁止。
