# KT reciprocalの固定全CLI比較条件

native32 comparatorをcloneし、計測7helpers・native引数・warm1+9/circular3・aggregation・quiet observerを保持。旧85source pinsと全proof predicate/DFS/current hold/afterを保持し、元ディレクトリ自身の5source pinはnative32正本への相対パスへcanonicalizeする。追加は新helper/source/contract・numeric/Model/codec証拠のpin/predicate/DFSと新candidate bindingだけ。旧candidate bindingは旧native32 codec証拠のcompiled nativeへの固定hash/長さ検査として保持し、新candidateは新codec証拠にbindする。

候補は新codec-native.exe SHA `74704D097CC6D70E531086DE73A3311716E1C3F96CEB62F6A5794067331B99FE`、controlは凍結balanced-KT SHA `7E149D682025E4E03EDC32B6999A91C139991DBC834017EF9A15F88EA9290BF0`、native7za26.03 SHA `EDBEE35370E14030E4C785CF88200F42DC651C1EB4217C1E3963C38A12F099B0`。Model proof62checks/59CLI/107identities、codec proof34checks/57CLI/81identities、tmp/reparse/変化/timeout0を前提とする。通常codecにaudit cfgはなく、表構築と524296Bを全process時間・peak memoryへ含める。

失敗条件を実行前に固定する: pin/predicate/source/AST correspondence不一致、再現証拠の長さSHA/hold/after不一致、CPU5×1秒preflight又は全child前後の15%超過、120秒timeout、exit/output異常、9測定欠落、frame不一致、native11件metadata/body不一致、復号不一致、既存work。新rootは `build/khc-bwt-causal-bayes-q32-kt-reciprocal-20261001/performance`、単回実行・自動retry禁止。旧native32 failed measurementは保持し、今回が新候補の測定であることを区別する。

固定group2811006B SHA `18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76`、frame483469B SHA `7584AF15ED4A70F6AD16E278F29DBB1C4D63EACD1DD58D5164198D03D3B5D95C`。size483599B以下・encode strict574.5624ms未満。nativeはgroupそのものではなく同manifestの11filesでsolid。`-t7z -mx=9 -m0=LZMA2:d=64m -mmt=1 -ms=on -mqs=off -mtm=off -mta=off -mtc=off`を変更しない。wallはlaunch前からexit/stdio drain後まで。直接decodeとnative SLTはround0/9、他roundは初回のverified frame SHA一致。decodeは1group/11filesの境界が異なるため診断のみ。

source correspondenceは親による検査であり新しい独立作者監査ではない。固定development以外のholdout・カテゴリ/幾何平均・同境界decode/peak memory・4native・製品統合がないため、この比較だけで総合7-Zip超えを宣言しない。unit/Git/外部write/CPU設定/x86/閾値緩和なし。
