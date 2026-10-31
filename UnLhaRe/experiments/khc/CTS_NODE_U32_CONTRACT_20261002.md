# CTS nodeの32bit保存: 実装前失敗計画

前goal turnは証拠285件の再照合と結果保存でPROGRESS。新候補はcompact fullから重みの保存幅だけを変更する。計算・Prediction・Q32・posterior・更新順・wire・schedulerは維持する。旧候補のterminal速度試行は再実行せず、初期化分離の提案は確認待ちのまま扱う。

## 仮説と反証

Nodeのu64 weightをu32へ保存するとNodeが16B→12Bとなり、7×131071 nodeで3669988Bを節約する。予測・更新結果とframeが旧実装と1bitでも異なる、合法な更新で変換が拒否される、実layoutが12Bでない場合は候補を棄却する。メモリ帯域・cache効率の改善は仮説であり、速度向上を型サイズだけで主張しない。

合法状態の上界: Q=2^32、更新後観測afterは1..562036803、alpha=floor(Q/(after+1))は7..Q/2。retained=Q-2alpha≥0、posterior≤Qより、next=alpha+floor(retained×posterior/Q)≤Q-alpha≤Q-7<u32::MAX。freshとleafのQ/2も収まる。最小値はalpha≥7。計算は従来通りu64、保存時はchecked u32変換とし、無検査truncateや飽和処理は使わない。範囲外のprivate状態まで旧u64保存と等価だとは主張しない。

## 検証前の失敗一覧

1. 上界の取り違え: 独立u128式と旧・新helper、境界after/posteriorと固定seedの65536更新を逐次比較。実際のchecked保存helperで0/u32::MAX/Q/Q+1/u64::MAX等を検証し、拒否時に保存状態を変更しないことを確認する。全観測回数の総当たり証明ではなく、上記解析と有限標本を区別する。
2. 暗黙cast・参照漏れ: 元compact source SHAと全文置換対応を保存し、重量読み出しはu64へ明示拡幅。既存next_weight/ratioとPredictionは変更しない。codec・scheduler・exact_ktは元全文と一致を要求する。
3. 状態差: standalone Rust CLIに凍結旧Modelと新Modelを同時に取り込み、7classの固定seed/連続/交互履歴131072イベントで予測・更新後全pathの85値を直接比較。raw出力は保存せず、件数・fingerprintだけ保存する。class拒否も旧新比較。これは数値/状態経路E2Eで、ユニットテストは追加しない。
4. 特殊化差: 数値/状態CLIとfull codecを各native/scalar×overflow-check有無の4条件で実行。コードを比較しないhashだけで同値と判断しない。AVX2使用は既存compact数値証拠を再照合する。
5. full経路差: 7入力のframe/stdout/復元を凍結旧integer候補と実byte比較、旧decoderとの双方向、破損5種、no-clobber、missing拒否を維持。固定complete frame483496B/SHA CF62CD2324B4CF889CDDDB25C9508C28E4BD4D24217B93BB7D4FF9318C3EAD12を要求し、サイズ上限483599Bを不変とする。
6. 実layout/使用未確認: 別の診断codecでNode12B・917497 nodes・11009964Bのheavy node領域を取得。旧16Bなら14679952Bとの差3669988B。compact kernel実使用、schedule、復元も同時確認。allocator overhead、light tree、journal、総RSSまで25%減ったとは扱わない。
7. 容量・副作用: 出力はbuild/khc-cts-node-u32-20261002に一度だけ、予算32MiB、事前事後guardと空き5GiB+予算。旧固定fixture・EXEを再利用し、Cargo target/cache/raw dump/PDBを作らない。sourceはapply_patch、失敗証拠は保持、自動再試行や上書きなし。変更担当は親のみ、製品コード・他版・公開・Git操作は対象外。
8. 評価の拡張: 正確性/layout検証の時間は正式速度に使わない。固定574.5624ms未満、CPU15%以下、warmup1+測定9等の速度ゲートを緩めない。holdout/カテゴリ、同境界decode、四native、製品/API組込み、安全性が揃うまで総合7-Zip超えやgoal達成を主張しない。

再現用CLI・実行argv・compiler/runtime/CWD/ソースSHA、件数と結果を上限付きreportへ残す。用途を終えた一時物だけ安全条件確認後に清掃し、証拠は削除しない。
