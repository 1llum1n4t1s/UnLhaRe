# Forest直接parse：失敗先行計画

2026-10-05。旧empty probe D32F332FBAB51D919B65F5D62588BA96CBC78BE891C5BEB6A5B7BAE7833CD79Eは保持する。親が全編集を所有し、他変更・既存証拠・x86版を扱わない。

失敗候補：別rootへの書込み、high履歴反転の範囲漏れ、default/nondefault混在、重複dispatch検査消失、最大深さ・frequency・padding・model数・trailing検査消失、途中エラーの外部公開、frame差、容量Statsの過少計上。最終Forestは従来同様zero初期化し、各モデルの3072行を互いに排他的なsliceとして渡す。parse_nodeの全検査と整数計算を保ち、root単位1024行へ対象を限定する。parse_rootの既存ローカル検証にも同じparserを使う。

根拠：Forestは284個の一時Dispatch（各3072行、24576 B）を確保して872448行（6979584 B）を再コピーしている。直接parseにより284回の一時heap確保・zero初期化と全行再コピーを除去する。最終dense Forestの確保とzero初期化は維持する。圧縮側にも同じparse呼出しがあり、wire/API/確率は不変。parse_dispatch_peakは一時heapなしの0へ変更し、parse stack等は既存SCRATCH_BOUNDで引き続き計上する。

基礎/終了検証は既存公開API E2E khc_block_normal、khc_block_adversarial、khc_model_boundaryを同じrelease Windows x64で実行。新unit testは作らない。旧/新paidとlowの固定7fixture、warmup1＋9、同frame・自己往復・相互復号を測定する。子64MiB/60秒、suite900秒、CPUquiet15%、report256KiB/output8MiB、raw/frame disk0。途中失敗は成功へ置換しない。採用条件は全互換・E2E成功と、一時確保284→0/再コピー6979584→0の構造的削減、速度/RAM回帰の有無を併記する。7-Zipゲートは変更しない。

opop全6観点は親が担当。Performance＝確保/コピー除去、Cleaner＝旧Reader::next/parse_packet_nodeを置換して旧経路を削除、Normalizer＝所有Vecでなく排他的sliceの標準borrow、Hardening＝既存検査維持、Tester＝上記E2Eとcrossdecode、Modernizer＝依存/API変更不要。Async＝同期parseのエラー時owned Forest破棄を維持、Startup/Intel＝独立候補なし/外部照会なし。

容量事前：共有Cargo6121013131 B、固定baseline5906793080 Bとの差214220051 B、累積上限256MiB、残54215405 B。新probeと3既存E2E/clippyのbuildを合計48MiB以内に予約し、終了時に累積を再確認する。現在free27443417088 B。新target-dir/依存/ダウンロード/削除/Git/公開/version操作なし。compilerはRust1.98.1、既存toolchain使用。超過時は追加buildしない。
