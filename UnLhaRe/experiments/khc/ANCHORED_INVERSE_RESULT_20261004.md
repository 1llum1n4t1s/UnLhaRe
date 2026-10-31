# 8-anchor逆変換：内部診断結果

単一スレッドで8経路のLF参照を交互に実行する候補を実装し、compile1/native1で検証した。製品実装・公開API・既存書庫形式には反映していない。opopの手順で成立証明、失敗契約、実装、同一EXE比較、親readonly確認を分離した。

## 正当性と境界

- tiny92件で独立suffix sortとBWT全文比較、原版・packed24・候補の全plain一致。SAとanchorの対応512比較、fallback28、全8剰余カテゴリ。
- 有限列挙1793件：255正常一致、1538をgenerator/decoderとも拒否。17不正入力を原reference/packed24/generator/decoderで拒否。
- 不正metadata9、fallback metadata1、拒否後復帰10。72行中8行しか巡回しない、全anchor終端一致の反例も拒否。primary再訪検査は各laneのload/write前に実行する。
- n=8388607/8388608/8388609の巨大境界で原版・packed24・候補の全出力一致。候補scratch実容量n、出力n−1、metadata32B。
- 独立数学的成立はANCHORED_INVERSE_PROOFに保存。全SA-IS実装の証明、metadata CRC保護、完成書庫の検証ではない。

## 内部計時

固定plain2811006Bを1read/BWT1、各warm1後9round、AB/BA交互、18計時全件保存。quiet CPU条件は未確認。

| 単体逆変換 | packed24 | 8-anchor |
| --- | ---: | ---: |
| 全9回中央値 | 48.4620ms | 33.5442ms |
| AB 5回中央値 | 51.6567ms | 33.5442ms |
| BA 4回中央値 | 45.21585ms | 32.1918ms |

全中央値は約30.78%短縮。scratch割当・初期化・検査・歩行・scratch解放と候補metadata parseは計時内、全plain比較とcaller出力解放は計時外。正式CLI速度や安定改善、7-Zip超えの主張には使わない。

32B metadata生成は別計時70.6117ms。LF構築・全歩行・scratch解放を含み、費用を無料にしない。この生成方式のまま総合採用はしない。次候補は、BWTがすでに持つSAの既存出力ループでSA[row]=(n−i*q)%nに対応する8行を採取し、追加LF構築・歩行を避ける方式。原BWT全文・primary・metadata32Bが現候補と一致し、生成増分を測る必要がある。まだ実装・計時していない。

## リソースと証跡

- 実peak WS122118144B、private119562240B、両方160MiB以内。BWT別phase見積141598926B、巨大reference130023437B、候補71303206B。
- outputはEXE284160B＋report46995B=331155Bのみ。raw plain/frameコピー、ASM、PDB、Cargo別buildなし。readonly時free53671366656B（約50GiB）、8MiB上限・5GiB最小残量を確認。共有作業による空き容量変動はこの実験の消費に算入しない。
- report SHA256 `3DDDA5809D5615E50017F012FCD22BD3AFEF424FF4A06B099F7ACEB34B40EEA9`
- EXE SHA256 `EDE58C62051203D85C52794F2EF91B3C5E1489644E0F523FBC2163FF9CA38B0E`
- runner SHA256 `CA684842B8553BB713F30F6C07EB5EAE15103D857B530A20AC652F13DFE5EDF6`
- 親readonly verifier SHA256 `B56137EAE4E321C729ED5E024D2CFF4673638E07FE8371FFE0AC7EAFAFAF9E7F`：exit0、47before/after/live組、raw stdout1、全18計時の中央値再計算、metadata LE・有限契約・容量・両peak・出力形状を確認。追加compile/native0。

GOALはactive。完成書庫サイズ・正式CLI速度・holdout・API・4nativeの固定ゲートは未達、変更・停止・緩和しない。製品dirty・依存・Git・version・x86・外部書込み・削除は変更なし。
