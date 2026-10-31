# 次のpayload構造上の問い：directモデルのcontext混入を区別する

前causal-direct-mixは568897Bの必要サイズscreenで不採用、全rootを凍結する。prior/precision/混合係数を変えて同じ案を再試行しない。今回の親読み取りは既存成功report SHA DB086C81EC77DD41EF3114C917081FC3FEC9495B879F1FE12BACEF9BC8B78AD3とmixture.rs/fenwick.rsだけ、新実行なし。

## ローカルの具体的証拠

mixture.rsのBank::rowはrecent/jointをhash(key)&4095で共有rowへ写す。key_bitmap/collisionは混入を記録するだけで、異なるcontextのcount更新を分離しない。保存reportには以下がある。

| family | distinct original keys | active rows | alias rows | row最初のkeyと違うevent |
| --- | ---: | ---: | ---: | ---: |
| global | 10 | 10 | 0 | 0 |
| symbol | 2423 | 2423 | 0 | 0 |
| recent | 53860 | 4096 | 4096 | 842410 |
| joint | 21737 | 4083 | 3978 | 1175562 |

これらは不一致event数であり、独立衝突回数・損失の因果量・改善可能bit数ではない。symbolの完全分離bankでもexpert lossがglobalより大きく、混入だけを失敗原因と断定できない。static/training-only jointの成績をcausal無衝突の性能として流用もしない。

## 未実装の構造候補と反証

異なるkeyをcount rowへ直接混ぜず、key→rowの完全一致辞書で分離する。固定RAM内に収めるため、prefix tree countをu32からu16へ縮小できるかを先に不変条件で確かめる。fenwick.rsは全count合計が32768未満を維持し、observe前にrescaleする。非負部分和は合計以下なので全Fenwick nodeも32768未満で表現できる可能性がある。これはコードのchecked条件からの導出候補であり、Rust/native最大境界検証前には採用しない。queryは広い整数へ昇格してchecked加算する。

従来u16 leaf＋u32 treeを、u16 leaf＋u16 treeへ変えることでrow当たり約1/3を削減し、recent65536/joint32768の別row容量を160MiB内で用意できるか計算する。row pool満杯時の挙動、decoder側辞書の決定性、未登録rowの初期prior、token limit、rescale中のprefix整合、hash探索上限、資源上限をコード前に一意に固定する必要がある。辞書collisionはkey比較で解決し、rowモデル混入へすり替えない。容量・CPU・counter幅の設定sweepはしない。

元prior/更新/混合方式を保持した無混入一候補の実際に使えるQ32768区間だけを一設定screenし、サイズ不達なら実coderへ進めない。幅変更と辞書分離のE2Eはdense oracleとのprefix/更新/rescale比較を親が設計する。サイズ合格でもdictionary/whole decode/encodeが速いとは未証明。現在のinverse候補が終わるまで実装を開始しない。総合goalの条件を変更しない。
