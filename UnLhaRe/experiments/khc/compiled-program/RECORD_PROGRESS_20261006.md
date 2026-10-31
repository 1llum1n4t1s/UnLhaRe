# 構造予測の再開現在値

最新はROW_COPY_PROGRESS_20261006.md。KRC1は実frame438280B見積りでsize通過もnormal encode+27.38%/decode+40.53%で未採用。別row-copy文法は逐次E2E/独立token参照/census成立、次はcausal-row-copy/BYTE_ENTROPY_PLAN_20261006.mdの未実装byte entropy実codec。原GOAL active/ゲート不変。以下は前工程。

2026-10-06 JST、原GOAL active。前turn/current Program+rANSに続き、今回は新record codecを実装・実行・有限E2E修復し、別の因果幅stateを実装・実censusしたprogress。pause/complete/blocked操作なし。

| 工程 | authoritative結果 | 次の判断 |
| --- | --- | --- |
| 固定prefix KRB1 record codec | 36selected+8forced/425952pixel参照/65534確率参照/22selector/4312異常検査（3636必須拒否）/11全byte・反復frame・保存/public一致 | 全legacyでframe+440B、467091B見積りは457415B失格。不採用、速度/sweep/製品移植なし |
| 因果pair幅voter | 26635全byte前/終端状態・393216全pair位置・全票が独立BTreeMap＋全票scan参照一致。11file全2810784byte public復元/逐次census | ptt5で前byteだけから216を選び460575B/約89.74%使用。新codec/率/速度はまだ未実装・未測定 |

最新根拠は ../record-bit/RESULT_20261006.md と ../causal-record-vote/RESULT_20261006.md。record guard不足を派生bで修復する際、emptyの全長cutを必須拒否と誤分類してexit1、派生cで実cutだけへ修復・再実行成功。失敗source/reportは保持。censusと実圧縮性能は明確に分離する。

次の **../causal-record-vote/CODEC_PLAN_20261006.md** を一構成で実装する。frozen voterを新KRC1 bit encoder/decoderへ同順序で接続し、保存strideを廃止。current byte前に幅を取り、動的幅に合わせleft4を復元済前byteから作り直し、byte全体完了後にobserveする。新header/legacy fallback/両試行/RAM/CRCの全費用を隠さず、同size-firstゲートで実frameを評価する。prefix範囲/係数/bitcontextを探索しない。

今回output4専用rootの計5884729B（約5.61MiB、source除く）、raw/frame/trace/PDB/newCargo target/共有cache削除0。Cargo6169422158B/cap6175228536B不変、終了free約48014147584B、所有cargo/rustc/probe/linkなし。製品5主要source pin（mod/grammar/packet/program/lz）不変。record fmt5source/parse3runner/diffcheck成功、voter fmt2source/parse1runner/diffcheckは終了確認に記録。source/EXE/reportは再現証拠として保持し、今回削除0。

親だけ編集、record_bit_contractはexplorer指定/役割実効gpt-6.1-sol medium readonly因果/境界/費用/harness反証。voter状態は親が独立参照を実装・実行。製品full build/Clippy/9E2E/.NET AOT/4nativeの今回再実行ではない。

原GOALは未達。現native466395B対7Zip481490B、5%まで8980B不足、復号約83対41ms、真正未見/encode・全費用/Zstd/最新安定基準/4native等が残る。実prototypeを製品統合完了扱いにせず、元条件を維持して次の実codecへ続行する。
