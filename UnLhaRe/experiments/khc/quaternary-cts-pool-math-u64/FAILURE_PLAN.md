# PERF-POOL-MATH-U64 failure plan (before code)

契約SHA256: 89D92DDA332CFB57DB74322814BAC53306DC00E9EB9282B3C283182F44BD07FB。
指定8filesだけを所有。前段Q-cancelは未採用で、旧depth5/旧poolを基点とする。旧source/証拠/製品/x86/version/cache/Git/外部操作と追加委任は禁止。

## コード前の失敗条件

- Math差分はln_scaled pos/idx/remとexp_neg mag/商余り/position/idx/rem2だけchecked u64化。guardとErr順序/文字列、LUT/counts、exponent/base、符号付き式、補間u128、cutoff位置を維持。overflowは旧unsigned product overflow、到達不能0除算も旧意味を保持。任意domainへ適用範囲を広げない。
- 旧新Math各1構築、l4097/e4097/counts32769全40963entryを前後2回81926entry直接比較。table群ごとの件数を固定し、生値列/traceを保存しない。
- ln unique97×scale[0,32,u32::MAX]=291、正常188/Err103。ln_count8、正常4/Err4。exp unique sorted36958、正常36954/Err4。method合計37257/正常37146/Err111、全戻り値またはErr文字列直接比較。ceil fixtureはchecked u128 exact、指数/grid±1・cutoff・domain外を含む。count不一致停止。
- poolは旧Prediction/Update/observeをreexport、predict全文/旧p u128normalize維持、Math importだけ変更。primary Prediction104/postreject12/total116、Update257、拒否12を旧Math/新Mathで全field比較。interior4/edge96/専用4とchild選択、BigInt正負/uniform q/rare q0 golden維持。Q-cancel20fixture/helperは含めない。
- codec旧bodyは前段旧codecと同一。子codecは前段から新Math aliasだけ追加し親Proof共有/free constructor全14field・2呼出・CDF to_bits・timer body維持。model/e2e/CTS/guard/seal/CAP/commitは凍結直接参照。
- snapshot sealed392/223/22、depth[4..8]30/1070/90/pure5/constructor2/compact60。selfcheck旧新各70plain/70canonical/165malformed/20short/70model named/80assertions/CAP5。拒否順/全state一致を削らない。
- ABBA depth5旧新新旧1周、入力2811006、frame478750/header285/payload478465、plainCRC433441561/payloadCRC3616798779/header621578488/base0caac94407124a37/CDF3820763.985142052±1e-4、全grammar/count/classes/nodes1365/storage196560を凍結。FIXED_STATSはDebug配列空白まで一致。全plain4/往復全Proof stats4/firstA全Proof stats3/frame全byte3・1436250B。size<=483599全4、warmup0/追加repeat0/inner timer0。
- firstA move保持/reference1枚478750B/live2枚957500B、clone/ディスクframeなし、timer外比較とcurrent即drop/最終reference drop。峰はencode成功直後guard前に記録。失敗経路counterは実績のみ、全process peakへ外挿しない。
- closure130 before/after全identity保持。旧118/106/99/89/84/72/60/48全loop/hash/bytes/UTCticks/EXEguard維持、旧Qcancel bothmean=false確認、旧Executeなし。冗長identity再保存だけscalar。graph17sources/18edges/root13/unique16、alias/body exact許可置換/validator定義呼出/CLI dispatch静的照合。
- fresh build/khc-quaternary-cts-pool-math-u64-20261003、8MiB/EXE1MiB/report512KiB/予約1572864B、空き5GiB+budget前後確認。既存root/reparse/混在/容量超過停止。child120s/stdout stderr64KiB、raw/parsed保存後validator、kill/dispose/finally、最終EXE/report2件だけ。input/plain/frame/temp/PDB/cache/traceのディスク生成なし。

## 実行境界と判定

nonExecute初回でtemplate pin移設の置換がgraph/Rustfmt先頭probe参照にも及び、旧qcancel codecへのunpinned edgeとして停止。新probe参照へ戻し、固定graph17/18と全10構文対象を緩和せず再確認する。compile/候補CLIは未実行。

workerはPS parser/Rustfmt stdout10/nonExecuteまで。型/compile/候補CLI/Execute/正式benchmarkは親だけ。両方向ABBA各2回平均が短ければ次研究基点候補、片方向でも短くなければ未採用、再測定なし。正式速度/CPU/holdout/categories/4native/製品統合/全process peakは未検証でgoal activeを維持。
