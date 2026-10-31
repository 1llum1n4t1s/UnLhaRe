# 旧Q32 depth5: 小容量stage診断の結果

## 結論

cfg依存修正試行はpassed。契約83case、全frame/plain比較、Proof14×2、全stats3組、174 identitiesのbefore/after/live照合が完了した。**性能改善候補を採用した結果ではなく、旧Q32の限定的なボトルネック診断**である。採用基点は旧Q32 depth5のまま。正式速度/CPU/holdout/4native/製品API/7-Zip総合超えは未達または未検証、goalはactiveでありpaused/completeにしない。

診断計測のtotalに対するpayloadは圧縮97.52%、展開97.83%。sampleされた3測定子ではpredictが最大で約74%。これはpayload全体の74%という意味ではない。次の限定調査はModel::predict内のCTS、pool/Math、context等を分離するのが妥当という仮説。未測定の内訳を断定しない。

## 実行・是正の経緯

最初のstage試行はframe_auditのみでcompile exit1、候補CLI0。凍結depth/modelのrejection_checksがprimitive_audit限定CTS seedメソッドを参照し、E0599×5になった。失敗report56374B/SHA `0D2DEDC2A4937361FE77C3F5C6C6EBE7ED38597C14653458E77478F36057563F` を保存し、169 source identitiesを親がlive照合、不一致0。旧4source/契約/失敗reportを凍結した。過去after/live未完了を成功としない。

新 `QUATERNARY_CTS_STAGE_PROFILE_CFG_CONTRACT_20261003.md` と新FAILURE_PLANをコードコピーより先に保存。新root `quaternary-cts-stage-profile-cfg/` へ同byteのcodec/probeをコピーし、runnerのroot/basis/174 identities/primitive_audit cfgだけを修正した。追加cfgはgraph内depth/q32 CTSのseed定義を有効にするだけで、opaque helper呼出を追加していない。通常数値/wire/CRC/state/総timerは前26観測allowlistと一致した。

独立readonly確認で先行操作のfixture誤帰属と、census例外でfailure保存が飛ぶ問題を見つけ、**初回compile前**に是正した。complete直前のcontext再設定も再確認した。cfg修正は別の固定契約で独立確認後に実行した。全体でcompile2（失敗1/成功1）、候補CLI1だけで、測定の再実行・選別はない。

## 実行記録と正しさ

修正試行のchild records4件: formatter2 exit0/stderr0、compile1 exit0、profile1 exit0/stderr0。compileは3.2915541秒、CLIは18.2037125秒、timeout/過大出力なし。既存depth CTSのunused imports警告1件/567Bを保持した。新unit test/旧opaque helper実行/製品・x86 buildは追加していない。

| 項目 | 予定/完了 |
| --- | --- |
| 契約loop/group/case | 12/12、13/13、83/83（Ok38、期待Err45） |
| synthetic STREAM/sample/scope pair | 3080/3080、16/16、64/64 |
| synthetic top pair/escape | 4/4、7/7 |
| codec calls | disabled参照encode1、計測encode1、計測decode1、各開始/完了1 |
| input read/空Instant pair | 1/1、10000/10000 |
| 全frame/plain直接比較 | 478750B×1、2811006B×1 |
| Proof/all stats | 14field×2pair（CDF bits）、3組exact一致 |
| frame所有 | 最大2枚957500B、最後参照0、frame clone/disk input/frame/plain copy0 |

synthetic拒否はResultと全State before/afterを比較、故意のMAX seedをAPI到達可能としない。実時計attemptsとcommit endpointsを区別した。今回の成功経路では一致した。

3組とも旧KHQCID01/header285/payload478465/plainCRC433441561/payloadCRC3616798779/headerCRC621578488、runs889227、primary1762795、alphabet257、rank/length889227、escape742、grammar58735a2b7383d755、base0caac94407124a37、CDF表示3820763.985142052、classes[889227,620240,1216305,889227,64372,145969]で一致。無計測参照は同bodyで時計/集約を無効化したもので、独立oracleではない。

## 観測時間（正式benchmarkではない）

単位ms。Model::new/finish_auditはpayloadに包含され、合計へ重複加算しない。top residualはtotal-transform-payloadで、header/CRC/packed/frame・非計測処理・観測影響を含む。

| 区間 | 圧縮 | 展開 |
| --- | ---: | ---: |
| total | 6091.5199 | 5968.4745 |
| transform（BWT/inverse BWT） | 144.7618 | 123.3028 |
| payload | 5940.5112 | 5839.1137 |
| top residual | 6.2469 | 6.0580 |
| Model::new（inclusive） | 2.7149 | 2.5230 |
| finish_audit（inclusive） | 2.8541 | 2.8572 |

参照encode total6020.2016msはこの単発診断内の値だけで、改善率や正式medianに使わない。空Instant10000pairのcounter/loop込み目安は0.5583ms、どの区間からも差し引いていない。

各方向3825340枝/component[2725772,1099568]/escape742。8層全数は[121,415562,13461,2296628,1,71469,7502,1020596]、sampleは[0,1623,53,8971,0,279,29,3987]で方向一致、総sample14942。全scopeが完了、top4bucket各1pair、時計attempts/commit endpoints各119544=8+14942×8。

| 同じsample枝の区間和（ms） | 圧縮 | 展開 |
| --- | ---: | ---: |
| branch_after_prefix親 | 32.5692 | 31.9079 |
| predict子 | 17.9229 | 17.6583 |
| range_and_selection子 | 1.8801 | 1.6643 |
| observe子 | 4.3376 | 4.3480 |
| 親−3子の同枝残差 | 8.4286 | 8.2373 |

predictは3子和に対して74.2438%/74.6001%。親と子を足さない。prefix確定/admit counterは親の前で、uniform escapeも時間対象外。残差にはedgeと観測bookkeepingも入る。prefix1の2層（n121/1）はsample0で、平均/外挿を作らない。周期同期、cold/rescale、時計分解能、分岐/counter/Stateコピー/時計の観測負荷が残るため、sample外挿をpayloadのexact exclusiveや純粋なCPU時間として扱わない。native reportは推計を出していない。

## 固定・容量・残存

graph10 unique/9edge、数値・state・wire・総timerの26置換allowlist一致。174 identities各before/after/live全件SHA/bytes/UTCticks一致、mask全111。失敗basis/Q21 parent_basisは別pinで各phase照合。親が終了後さらに174source＋basis/parent_basis/EXE3を独立live照合し、不一致0。readonly担当も件数/比較/時間解釈を確認した。

| 保持物 | bytes | SHA256 |
| --- | ---: | --- |
| cfg EXE | 366592 | 4ADAEB4E4201D100C27833FEA462214444F3EF826D942739ACE62BE37256223D |
| cfg report | 70850 | 1A5D148CC5E7D2B46F7C30BB646FB8DDB8FECE72E9FDA37C2E8350DC184E3528 |

EXE before/after/live同一。cfg rootは2件437442B（約427KiB）。前失敗report56374Bを含む診断build保持は493816B（約482KiB）。cfg source4件100138B≤300KiB、native stdout7509B≤16384B（事前projection15429B）、report≤256KiB、保持≤1.25MiB/fresh8MiBに合格。report.disk_after.used_bytes366592はreport write**前**で、最終サイズではない。

終了時と親追加確認で所有診断EXE process0。これは全machine CPU0の証明ではない。直近空き87729750016B（約82GiB）、drive全体の変動を今回の小出力へ帰属しない。削除操作0、今回用途終了の大きな一時物なし。新Windowsごみ箱移動/完全消去手順の動的検証は行っていない。

compile失敗のnonzero/stderr/report保存は最初の試行で観測した。ただしCIM失敗/panic/timeout/JSON不正/heap/write/sync失敗注入は未検証。正式median574.5624ms/CPU15%/独立holdout/categories/4native/製品API gateは未達のまま。次はこの凍結証拠を保持し、predict内の少数区間だけを別のコード前計画で分離する。
