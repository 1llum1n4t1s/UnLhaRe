# 静的class選択とteacher状態の独立監査

結論：class2/5のwire予測を静的CDFへ置き換えてもteacher predict→observeの全省略は成立しない。独立analystは当初4資料と親承認のModel本体1資料の計5資料を読み取り確認、編集/compile/native/Git/外部/削除0。親は重要なModel/pool/CTSと呼出し元コードを直接照合した。これは状態依存の調査で、実差分証明はまだ未実行。

- anchored-wire/codec.rsのStream::tokenはprefix→predict→interval/select→edge→observe、run_doneでprevious/recent更新。lazy_model.rsのpredictは4count snapshot・CTS・poolのfeatures/q/p/weightsを準備し、observeはそれらから勾配、4共有table加算/rescale、CTS raw/価格/履歴/best/splitを更新する。
- hash table1..3はclass専用でなくrow_idsの固定maskで共有するため、選択classの更新省略は非選択CDFへ波及し得る。serial、weightsのfloat bits、snapshot鮮度、k1更新、previous/recentも維持する。staticCDFをpool予測の代用にすると重み更新が変わる。
- teacher frequencyはobserveのentropy監査にも必要。features/log/exp/q/p/gradient/CTS価格が残る中、wire用cumulative生成だけ遅延する局所候補は成立し得るが、最大4要素の省略であり大きな速度改善の根拠はない。frequency支持/tail/total検査は維持する。採用実装なし。
- 差分検証は選択/非選択/k1交互、共有row衝突、rescale、stale/CAP/価格overflowを含め、各非選択CDFと更新に触ったcount/weight/CTS/serialを直接比較、最後に全所有状態とauditを照合する。digestだけはCTS/serial/全auditを覆わない。primary audit TLSを2Modelで混同しない。巨大trace保存ではなく逐次比較する。
- CTS拒否前にbase/pool/statsをcommitしない順序を保ち、Snapshotは1branch寿命とする。測定段はteacher準備／CDF／observe／coder／static学習・metadata／全encode/decode。35.6%wire置換率を速度削減率とみなさない。

対象：anchored-wire/codec.rs、hard-cut-model-lazy/adapter.rs、hard-cut-lazy-errors/lazy_engine.rs、lookup-float-cts/float_pool.rs、hard-cut-model-lazy/lazy_model.rs。Performance/Hardening/Tester/Asyncを確認、依存更新・標準化・整理・外部仕様・起動に関わる変更は今回非該当。元速度574.5624/47.3884msの固定全条件を維持し、teacher参照lossだけの費用screenを完成codecと呼ばない。
