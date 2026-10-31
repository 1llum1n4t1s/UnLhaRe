# 無混入direct contextの実装前RAM導出

DIRECT_CONTEXT_ALIAS_QUESTIONの候補をコード前に容量だけ確認した。parent JavaScript整数算術で下表を再計算、Rust layout/Vec capacity/実peak・サイズ・速度は未検証。候補はまだ実装しない。

| 項目 | 固定導出B |
| --- | ---: |
| global32 + symbol16384 + recent65536 + joint32768 rows | 114720 rows |
| u16 leaf257 + u16 Fenwick258 + u32 total4 の各row1034B | 118620480 |
| recent/joint辞書各2倍slot、slotはkey u32 + row u32 | 1572864 |
| 全rowの登録key u32（terminal照合用） | 458880 |
| 上記model合計 | 120652224 |
| 凍結run capacity1048576 ×12B | 12582912 |
| 入力2811006 + frontend余裕1369112 + 4MiB余裕 | 8374422 |
| fixed mix phase合計 | 141609558 |
| 160MiBまでの差 | 26162602 |

他の実配列・alignment・dictionary statistics・小oracleは実装前に追加して再計算する。BWTは別phase141598926Bの旧導出で、両phaseを同時保持しない。合計約135MiBはallocator/OS実peakやquota保証ではない。65536/32768 rowsは一候補のpool上限であり、全private inputで足りるという保証ではない。上限超過は明示Limit失敗とし、hashで別contextへ黙って混ぜたり、資源閾値を緩めたりしない。固定corpusで充分でもholdout/category/総合性能は別途必要。

counter幅の前提は元fenwick.rsのtotal<32768、非負leaf、nodeはleafの部分和、observe前rescale、checked addである。初期化・rebuild途中も部分和が最終和を超えないこと、prefixはu32へ昇格して加算、更新/拒否時に不変条件を破らないことをnative dense oracleで確認する。古いu32 Fenwickのサイズを根拠なくu16へcastする変更はしない。最大値/再scale直前直後のE2Eをコード前に設計する。

辞書は同一keyを同一rowへ写す完全一致mapであり、hash collisionはslot探索で解決する。満杯/誤key時のtransaction、encoder/decoderでの決定的登録順、bounded probe count、未登録row priorを計画で一意にする。prior・重み更新・Q32768区間の規則は元と同じで、context分離の一設定だけを反証する。size-first screen不合格なら実coder/正式速度へ進めない。
