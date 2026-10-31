# 独立数値・状態検証の実装前失敗計画

対象はKHNDR001のCDF primitiveのみ。oracleは生配列、全prefixの通常u128除算、線形slot探索であり、候補Fenwick/逆数/floorを再利用しない。

- cold alphabet1/16/256/257、key1/4096、prefix0/full、limit1/Aで支持・total・切り詰めを誤る。初期全intervalと境界slotを独立比較する。
- D1/16383、T0/16383、閾値近傍、固定seedのD/T組でden/reciprocal/n0/最大mass/商補正を誤る。各q0..32768のceil(q*den/Q)前後massとR/L端点・seeded prefixを通常u128除算へ比較する。逆数近似が1小さい証人を最低1件記録する。den全数走査は行わない。
- Fenwickのノードごとの丸めや探索境界が誤る。393216更新イベントで独立interval/linear select、定期全tokenの両端slotを比較する。
- global/local rescaleがずれる、hot globalをcold localへ反映しない、拒否updateが部分更新する。配列のceil-halfと全counts/rescalesを照合し、cold/hot分布証人、invalid key/token/limit/slot前後のstateを比較する。
- preparedDistributionのtotal/interval/selectが異なるCDFを使う。読み取り借用内で同じqueryを再利用し、wrapperも照合する。
- source/import/compiler/runtime/EXEが変化する。最終source SHA通知後のみ、read lock、import閉包、実行前後identityを照合する。
- 容量超過・子timeout・大量ログ・Cargo/PDB/raw trace生成。fresh build/khc-direct-token-dirichlet-model-20261002、8MiB、4EXE各1MiB reserveとJSON512KiB、子120s/stdoutstderr各65536、debuginfo0/DEBUG:NONE。予想約1MiB。既存rootを上書きせず同条件再試行なし。

opt2/3×overflowyes/noの4条件で全stdout一致を必須にする。allocation失敗注入、full grammar/container、圧縮比、速度、他native、製品統合はこの検証では未実行。Git/version/公開/外部書込/x86/共有cacheを操作しない。
