# 次の問い：時間partitionの保存費用を払えるか

固定65536-run/14tileの無料Qscreen452387B（token449308+side3079）を実測した。固定483599Bまで31212Bしか残らない。14tile全体active180526rows/pure78971/nonzero354913、in-sampleで無料保存分布の結果。実coder/paidモデル/速度/holdout未検証。

既存class-selective-static-mdlのFit/個別serialize/parse/bundle方式を、component/node/prefix/history10×tileへ単に反復するのは費用増大が強い反証になる。固定tile幅のまま、空root・uniform root共有・node/prefix固有の使用数・既存history tree剪定を使って、token増分と保存費を実計上する一候補へ絞れるか。モデル量子化の変更、teacher無料値、別幅sweep、サイズ条件の緩和で逃げない。

読み取り調査の範囲は既存model.rs/bundle.rs/probe.rs/RESULT.mdと新temporal tiles/probe/保存reportのみ。設計は最小の診断で、Dense1reuse・旧source不変・source/EXE/report予算を維持する。全tileを保持する巨大表や全CDF traceは作らず、モデルは逐次費用化しserialize/parse一致をRAMで検証する案を優先。既存最低header費を全形式の下界と呼ばない。

必要な返却は一候補の具体的key/layout/保存費算術/最強反証/先行有限E2Eと実測で棄却する条件。7-Zip超えの採用判定ではなく、無料情報利得をpaid実装へ接続する可否の問いである。
