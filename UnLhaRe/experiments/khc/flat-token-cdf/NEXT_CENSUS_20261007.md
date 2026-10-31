# 次工程：実tokenのleaf memo census（未実装・2026-10-07）

親だけprivate census filesを編集する。native/既存block/record/wireを変更しない。採用の前提はflat-token-cdfのFEASIBILITY、選択pathのhistory更新と支持区間についての原典確認、整数execution witness（compiler資源失敗とは区別）。この工程は速度証拠ではなく、低費用で設計を反証する統計だけ。

既存block/mod.rs SHA B050BBF7EBF988A50514146C39501F3EB6DB758051DA601968ACD70A65793984をnamespaceコピーし、14child moduleを現在の製品sourceへreadonly参照。token入口でcomponent別3history/limitをsnapshot、旧decodeはそのまま実行してsymbolと終了historyを得る。戻り時だけ観察表を更新し、確率/consume/active/CRC/逆BWTは変更しない。
固定65536cellの24B配列（1.5MiB）をdecoder/forestごとに作り、別blockに共有しない。keyは非zero tag＋component1bit＋limit-1の9bit＋history3×10bit、完全比較する。固定hashで1cell direct map、同key同symbolのときだけpossible hit。hit/miss/collision・元paid/implicit branch数・rank/length別支持と行程を数える。cacheは本工程では復号をskipせず、newwireのslot/interval算出もしない。将来のencode/decode hit条件を緩和しない。escape ULEBは別fieldのまま。
元Canterbury development11件の保存済みnative revision2 archiveからframeを借用して、public/raw/source/hash/全byteとprivate decodeを照合する。shared corpus/cached sourceはコピーしない。出力は小JSONだけ、frame/raw/trace0。全methodを区別し、MDL以外はmemo対象外として報告する。
memはbaseline phaseにcache＋raw/caller/archive/小resultを加えて64MiB内、codec16MiB?ではなく実child64MiB。新unit testは作らない。失敗先行：keyのbit重複/h=1024/N0/258/c>1、stale別forest、hash collisionの誤hit、開始/終了history不一致、k1漏れ、既存frame/CRC差異、raw/frameextent、明示フィールド配置24Bを超えるallocation、OOM/上限/timeout。invalidは握り潰さない。
compileも含む最大専用8MiB/report64KiB、既存release deps/standalone rustc、Cargo増分0、新target/download0、free5GiB+8MiB、compiler512MiB/60s・child64MiB/60s・suite300s・CPUquiet15%/60s。一時link objectが必要なためarithの1MiB予算を使わない。これは別codec censusの事前予算でありarith失敗を合格へ変更するものではない。
結果を見てcache可能性と生成費用を判断する。hit率だけで2倍高速化を断定しない。全leaf probability生成・全context CDF512GiB table・パラメータsweepは行わない。次にbackend/codedframeを作る場合は別versionと追加finite E2E/paid rate proof、normal/逆順速度gate、native全費用/未見/Zstd/最新7Zipを必要とする。

