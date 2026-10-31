# compile-time復号program：両順の局所条件を通過

2026-10-06。data-independent grammar/prefixをconstfnで検査・構築してreadonly参照にし、runtime CDFの検査済み累積変換はin-placeのまま保つ。元runtime表のsmall4file遅化を受けた別構成であり、サイズ別fallback/標本選別/係数変更はない。

| 集計・順序 | 旧decode ms | 候補decode ms | 短縮 | encoder比 |
| --- | ---: | ---: | ---: | ---: |
| file中央値合計・通常 | 93.3749 | 44.9125 | 51.900886% | 0.988005 |
| pair合計中央値・通常 | 94.6394 | 45.2579 | 52.178585% | 1.002902 |
| file中央値合計・逆順 | 92.0756 | 44.0736 | 52.133247% | 1.037917 |
| pair合計中央値・逆順 | 92.9571 | 44.0881 | 52.571563% | 1.042285 |

両順とも8MDL各file10%以上遅化0、全11frame465951B完全一致。局所15%decode/encode5%/per-file条件は通過した。これは同EXE内の独立namespace比較で、公開API/実書庫の52%改善や7-Zip総合/未見優位の証拠ではない。全metadata/終端/CRC込み、program表構築はcompile時に移しEXEと常時rodata費用へ含めた。

通常report `build/khc-static-program-a-20261006/report.json` SHA256 `63B6648AF460690BAB3140E4DC447C0692C4668F4C4DFB4D019130ECDBFE736C`。独立reverse `build/khc-static-program-reverse-20261006/report.json` SHA256 `89E3286DBCCD9224EF6AA466551ED9ED442061167836EB06C17FAE8EC5DDE69A`。reverseはnormal report/source/input/EXEを再pinし同EXEを使用、入力順・pair先行を反転した。

EXE1486848B SHA256 `5B2C98E568EB01D324E07444C58685635334DE348513A79D17B37ED370FCDCF3`。runtime表EXE1414144Bに対して72704B増。モデル/辞書をframe外へ移した費用隠しではなく、固定wire geometryの実装データである。宣言constのアドレス同一性には依存しない。型と借用により各呼出しのheap/表コピーはなく、物理的な格納数の一意性は宣言constから断定しない。

両runで532152 numeric（66049route/72846shape/CDF393257）、全8MDL6979584 CDF行区間端の直接一致、49raw/全11旧新public encoded frame/復元一致、684decoder異常（660拒否）・2witnessでgap/normalize切断をCRC/extent修復後の実内部errorとして確認。誤り後の同process回復も通った。全Malformed・全OS・最大Forestのruntime完備とは区別する。

独立analyst compiled_program_contract（指定analyst/役割定義gpt-6.1-sol medium、read-only）でforward/depth8・全limit/terminal/k1/class/CDF型・全容量・採否条件を確認。全行CDF検証で旧受理を狭めるH1はpaid_model::valid_frequency/parse_node/parse_packet_node_intoとmodel::quantizeの全行充填を追加照合して反証。static版のcutとalphabet256末尾空edge除外も旧Treeと同じ。stageのconstructorコストだけに因果効果を分解するclock測定はない。

compiler通常private323481600B/WS301084672B、finite childprivate27570176B/WS31379456B。samplerはOS quota/真の全peak保証ではない。Cargoこの比較時点増加0、PDB/plain/frame/trace0、source/report/EXEを凍結保持。製品への仮統合と検証の現在値はPORT_PROGRESS_20261006.mdへ分離して記録する。GOAL active、元native全書庫/強solid/真正未見/7-Zip固定条件未達を維持。
