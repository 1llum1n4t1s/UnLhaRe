# runtime固定表：通常順39.8%短縮でも非採用

2026-10-06。report `build/khc-compiled-program-a-20261006/report.json` SHA256 `AE0A50C74EF2EC43E8AAC7B3B3C8DDE6A3DEE43BBEDEF15590FC512972E44A8C`、EXE1414144B SHA256 `2AB86B0101F7E06C2CCDC54E3B4C1ED4E8D77F52201D57533DD0922B68801639`。status completed/exit0、pin終了一致、532152 numeric（66049 route/72846 shape/CDF393257）、6979584実CDF行区間端、49raw/全11旧新public encoded frame/復元一致、684異常（660拒否）、旧新のgap2/normalize切断2を直接検証。全frame465951B不変。

通常8MDL decode file median合計93.5861→56.3419ms（39.796722%短縮）、pair合計中央値94.2305→57.2949ms（39.197075%短縮）。encoder比0.982204/0.988679。cp.html1.4982→2.3013ms、fields.c0.7952→1.7995ms、grammar.lsp0.5160→1.6453ms、xargs.1 0.5289→1.6369msで4fileが10%以上遅化。元per-file条件を満たさずこの構成は非採用、reverse/同EXE第三性能測定なし。

runtime Program::newは入力に依存しない142×513=72846 prefix問い合わせとTree2本/配列を毎回構築する。小fileでほぼ一定1.1ms前後の増加が見え、その構築が要因である可能性があるが段階時間の直接測定による原因確定ではない。次の別構成は同じgeometryをconstfnでcompile-timeに検査・構築し、static immutable code dataへ含める。private検査・CDF/runtime意味・予算・元gateを維持し、startup/I/O/EXE増加/常時rodata費を隠さない。結果に合わせたサイズ別fallback・選別・除外・係数変更ではない。

compilerprivate323575808B/WS296742912B、finitechildprivate26722304B/WS29458432B。warning unused geometry local k1件は診断のみで、凍結sourceを修理しない。source/current core/固定入力/Cargo増加0。現GOAL active/7-Zip総合未達、元fullnative/強solid/真正未見gateを局所改善へ置換しない。独立analystのparser全CDF受理条件照会は親がpaid_model::valid_frequency/parse_node/parse_packet_node_intoの全行充填を確認し、別局所照合を依頼している。
