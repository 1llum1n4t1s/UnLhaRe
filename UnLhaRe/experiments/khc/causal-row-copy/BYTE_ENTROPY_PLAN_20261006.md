# 次の実codec：row-copyの2byte-field static rANS

2026-10-06。censusの区間削減は成立したが生fields86175Bは大きい。そこで一構成を固定する。token grammar/最大copy/XOR非0 residual/frozen causal voterは変えず、length ULEB byteとresidual byteを**別の2静的CDF**で符号化する。rANS式は既存 ../mdl-rans/entropy.rs の作者出典を保持して再利用する。既存学術原理の独立組合せ/改良で、新原理/世界初/総合勝利ではない。

## 保存するモデルとcoder

- 初段のtoken scanで2×256 u32 field histogram。第二scanで同じtokenを生成し、ULEB length fieldはmodel0、非0 XOR byteはmodel1から各一intervalを送る。tokens/journal以外の生traceは保存しない。2scan/legacy試行/model/coder費用をencodeへ全課金。
- 各modelの総頻度32768。観測symbol各1をまず確保し、残32768−supportをcount比の整数floorで配分、残りtickは剰余が大きい順・同点低symbol順に配る。floatなし。頻度0は未観測symbolだけ、freq最大32768をu16で保存できる。
- wire modelはLEu16 support(0..256)と昇順の(symbol u8,freq LEu16)を列挙、2model計4..1540B。length modelは非empty、residualはliteralなしならempty可、symbol0残差は禁止。sum32768/頻度正/厳密昇順/完全extentを確認。decoderは各32768slot→u8のLUT（合計65536B）を確保前/後に課金し、空modelのreadを拒否。
- scalar rANS total32768、単一state/prefix5/正準全byte消費と終端LOWER。2^21events cap/12MiB retained＋6MiB再確保old領域を維持。全不一致1MiBならfield2×rawでcap内。頻度32768のsingletonを暗黙化する最適化やlane追加はこの一案に混ぜない。

## 私的frameと復号

new magic `KRP1BLK\0`、revision1@8、methodu8@10(0 raw/1 copy-rANS/2 KHC1内包)、flags0@11、raw LEu32@12、model bytes LEu32@16、payload LEu32@20、rawCRC@24、wireCRC@28（28..32以外）、reserved0@32..40。header40B。method0/2はmodel0、codedはpayload>=5、model+payload<raw、raw<=1MiB、frame<=raw+80。unknown/旧KRC/KRBを拒否。内包KHC1のlen/CRC/上限保持。

decoderはmodel0からULEBを最大3byte/正準最短で読みcount<=remaining。各copy byteで幅を取り、previous output又は0からbyteを復元後vote更新。remainingがあればmodel1から非0 residualを読み予測XORしてvote更新。terminalに無literal、0countには必ずliteralという文法で進捗、終了後rANS finishとrawCRCを確認。外部辞書/未来データ/floatなし。

phaseは旧baseline peakとrecord phaseのmax。旧Front/fit/modelはencode呼出しから返る時点で解放されていることを確認して、record phaseには保持中legacy frame、raw、2histogram/CDF/LUT、voter266372B、journal18MiB、出力/payload/frameと一時再確保を全て課金する。旧peakにjournal18MiBを重ねて生存するとは扱わず、逆に既存frame等を忘れない。64MiBを超えるなら勝手に拡大せずgateを守る。

## 検証と判定

normal/異常の失敗先行：integer normalize全support/極端count/tie、serialize/parse/CDF/LUT全32768slot・未観測/空model、singleton、ULEB非正準/4byte/remaining超過、zero residual、missing/extra token、rANS initial/truncation/termination、flags/magic/model length/CRC、空/境界/任意/白prefix/1MiB/直外、拒否後復帰。新unit testなし、実frameと独立token/CDF参照をE2Eで照合。

固定11実frameの全byte/反復/現baseline/public一致、全frame+444+256<=457415Bのsize-first。通過時だけ全費用encode/decode normal+reverseの次gateを事前固定。元GOAL_GATE_20261005.mdの強7zip以下両時間/真正未見/全費用/RAM/各native統合を維持。ptt5のコピー割合を速度改善へ変換して宣言しない。

専用root8MiB/report128KiB/free5GiB+8MiB、helper/codec64MiB/compiler512MiB/child60秒/suite300秒/quietCPU15%60秒、Cargo固定cap・raw/trace/PDB/newtarget/削除0。親だけ編集、frozen proto/referenceを上書きしない。現在の製品/API/wire/version/他版/Git/外部write変更なし。
