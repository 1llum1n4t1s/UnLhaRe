# Forest採用後の7-Zip直接比較：未達

対象はCanterbury development全11ファイル2810784B。2026-10-06、公開public-e EXE SHA020ACFC3E9DFC5400EA99928B4ED33EAA619CA886D7D53DE67829FEDF48EED9D、固定7-Zip26.03 x64 SHA EDBEE35370E14030E4C785CF88200F42DC651C1EB4217C1E3963C38A12F099B0。条件はSEVEN_PLAN_20261006.mdに事前固定。xz/LZMA2 mx9/4m/fb273/1worker、KHC BinaryAdaptive、各64MiB観測上限、warm1＋9 pair、process起動・binary IO・pump込み。raw/frameはRAMのみ。未見でも全native archive比較でもなく、4mは既存block診断の設定である。

| 順序・方式 | 全frame/xz B | 圧縮中央値合算 ms | 展開中央値合算 ms | 観測max WS B | 観測max private B |
| --- | ---: | ---: | ---: | ---: | ---: |
| 通常・7Zip | 492380 | 1217.5981 | 989.5705 | 31899648 | 57790464 |
| 通常・KHC | 465951 | 1202.2157 | 980.8916 | 27955200 | 25522176 |
| 逆順・7Zip | 492380 | 1280.2646 | 1062.1644 | 31895552 | 57794560 |
| 逆順・KHC | 465951 | 1305.1747 | 1025.3283 | 27955200 | 25522176 |

総費用5.37%削減は両順で同一。通常順はenc約1.26%/dec約0.88%短縮したが、独立逆順ではenc約1.95%遅く、率優先ゲートのenc/dec双方以下が再現しなかった。速度優先10%ゲートも満たさない。通常順の小さな勝ちreportだけを選ばず、7-Zipを超えたとは扱わない。

ばらつきも重要。通常順の各round全11のnew−old合計差msは、enc [11.8467,-9.8304,48.0532,-25.1307,65.8739,25.0413,0.3163,-111.9439,32.8372]、dec [9.7396,-6.6886,-40.9594,25.0382,26.7995,114.3779,-17.804,-5.9949,-29.877]。平均差はenc +4.1182/dec +8.2924msで、入力別中央値の合算とは一致しない。参考のpaired差t95区間はenc[-35.8241,44.0604]/dec[-27.0071,43.5919]msと0をまたぐ。これは独立性を証明しない記述的な近似で、中央値ゲートの変更や性能優位の証明には使わない。逆順もenc [-371.9712,91.7954] / dec [-135.4339,110.4412]msのround合計差範囲であり、小差だけを測定誤差より強い勝利と扱えない。

両順計880 native calls、440自己復号が全byte一致、全6report completed / live pins true。異なる形式なのでframe一致と交差復号は非適用。出力report計190987B、各8MiBとfree5GiBの事前事後確認成功、終了空き45995139072B。追加Cargo生成・download・raw/frameディスク0。独立逆順はpartition c→b→a、各partition descending、pairも反転した。これ以上同条件を盲目的に再実行しない。

| build内 report | B | SHA256 |
| --- | ---: | --- |
| khc-forest-seven-20261006-seven-a/report.json | 32329 | B84BD1429922D6E234C741591D06E37838661BD0D6A3090EC81B28A8A616B5B1 |
| khc-forest-seven-20261006-seven-b/report.json | 32690 | 03A0BA6AA306CAD7AA356758713678260892E53876D1D43C1A87546D52FA457A |
| khc-forest-seven-20261006-seven-c/report.json | 29874 | 5511DB749C0664B025B199218DAE22FFB753CBAA072CAEDFF64D48121592D04D |
| khc-forest-seven-reverse-20261006-seven-reverse-a/report.json | 32775 | 564ED4F0F1E400C585F696F59D08DA29D2C784FE806652B134733498D91D6741 |
| khc-forest-seven-reverse-20261006-seven-reverse-b/report.json | 33087 | BF2701EC32197B20BF22A5D40CACFE9C299D02E19889A58F0203ABCDC77F4258 |
| khc-forest-seven-reverse-20261006-seven-reverse-c/report.json | 30232 | F144310AA5534E19BA7EC5093241C2055BCE25F0B5E7428070570154D811FD3C |

次は圧縮側MDLモデル構築の工程実測を優先し、未測定のdecode2候補は別ablationとして保持する。既採用zero-row/ordered-next-use/tokenRoutes/Forest共有表や既棄却slot融合等を反復しない。全archiveの強い設定、真正未見、Zstd等との公平比較、4native OS、独自性/量子技術の一次資料確認を含む元のGOALは維持し、active/未達のまま継続する。
