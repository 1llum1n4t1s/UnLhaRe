# 因果的Bayes + packed alphabet — 全frame/decoder契約

前段report `build/khc-bwt-causal-bayes-packed-20260930/evidence/report.json` SHA `6FE5DC5B34A5F10A6FB6C63B03CE92DA6398D27A228C7ACEA0A80B884474AE30` は、実aux483,187 + metadata245 +基本header36 =483,468 bytes、gate483,599より131 bytes小さい。aux自体は未復号だった。この契約は同一構成を完全codecへ移すための別段階で、旧研究codec・凍結diagnosticのsource/reportを変更しない。

## failure-first

- decoderが現bitを知らない時点でprimary/CTS/Bayes予測を再現できない、更新順がencoderと異なる、componentが別確率で学習する。
- headerからの加算/index/長さ/bitmap count/permutation rankを信用する、欠落sentinel/不正padding/extra bytes/非正準range終端を受理する。
- CRCを修復した不正入力を意味検査が見逃す、CRC確認前に出力を公開する、既存outputを上書きする。
- debug診断やselfchecks/複数aux writerをfull codec hot pathへ残す、時間測定と診断実行を混同する、size passだけを総合達成とする。

## 単一frameと同期

magic `KHBAY001`、基本header36 bytes。offset8 plain length、12 BWT primary、16 alphabet count、20 payload length、24 plain CRC、28 payload CRC、32 header CRC、全LE u32。offset36から正準packed alphabet表（33-byte bitmap + ceil(bit_length(k!-1)/8)LE順位）、続いて終了済みQ15 range payload。header CRCは先頭32 bytesとpacked metadataの連結IEEE CRC。旧headerと同じ費用だが異なるmagicで混同を拒否する。

byte+1/sentinel0の元方向BWT、next-use rank→run length grammar、primary4予測器および更新、D16/Q48 CTSの数値式、7 class毎prior1/2の因果的Bayes、Q15丸め/補数/終端を前段と完全に一致させる。decoderもcomponent両方をbit前に予測し、そのQ15 mixtureをrange decoderへ渡す。bit判明後だけBayes component累積損失、CTS、primaryをそれぞれ更新。encoderのexpected bitを予測に渡さない。thread-local診断でなくstream所有の状態を用い、decodeごとに新規初期化する。

上限input8 MiB、payload=8MiB*16+1024、frame=payload+281を維持。headerのalphabet countとbitmap popcountは一致、rank<k!、metadata幅/全frame長が一致、primary≤plain length、plain長+1のBWTとsentinel/active-list完結・inverse BWT・plain CRC・range decoder finishを全部確認してからno-clobber publishする。新製品wire/default/APIへ統合しない。同期API/全入力保持の研究prototypeである。

実装は `experiments/khc/causal-bayes-packed/` の新standalone codec/必要moduleだけ。CTS数学部分とprimary/grammarは凍結sourceから抽出/複写したことを明示し、元fileを改変しない。単回writer以外のsite/shadow/diagnostic selfchecksは新codecのhot pathへ持ち込まない。source由来f64/logit/sigmoid/exp2/log2決定性は現Windows/toolchainで実測する範囲で、異なるCPU/OSでのportableformat保証は未達。深さ/prior/context/係数/sweeps、依存/version/Git操作、UnLha32Re、holdoutは変更しない。

## E2E・採否

新unit testなし。別process2 encodes +decodeでempty、single low/high、全256 bytes、反復/周期、固定seed mixed、fixedgroupと11 entriesを全byte/SHA/metadata照合。全固定frameは483,468 bytes、payload483,187、packed245と前段に一致することを要求し、不一致は勝手にgate変更せず原因を修正する。別最適化levelでcompileしたreference decoderでもfixedgroupを復元し同一frameを確認する。

不正magic/header CRC/payload CRC/plain CRC、短header/短payload/extra byte、plain/primary/alphabet/payload overflow、header countとbitmap不一致、padding/missing sentinel/rank≥k!、正しいCRC付きrange prefix/termination破損をCLIで拒否しexit1/stdout空/公開なしを照合。encode/decode既存output保持、上限/不存在/既存workを検証。source/全module/range/harness/toolchain/binaries/fixedgroup/manifest前後SHAをreportへ残す。

専用所有基点 `C:/Users/IMT/dev/UnLhaRe/UnLhaRe/build/khc-bwt-causal-bayes-full-20260930/` を用い、不要smoke/PDB等は範囲とprocess終了確認後のみ安全清掃する。以前policy拒否対象は扱わない。CRC/正準拒否/復元とsizeが通って初めて、別のpaired fullencode/decode/OS peak計測へ進む。fixed sizeだけでも7-Zip総合超過ではなく、encode<574.5624ms、decode/peak、カテゴリ/holdout/native-solidは未達のまま維持する。
