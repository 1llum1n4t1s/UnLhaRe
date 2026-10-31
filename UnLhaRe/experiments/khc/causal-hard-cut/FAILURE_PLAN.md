# causal hard-cut：実装前有限E2E契約（第一段階）

QUESTION SHAFA4803158022EF3F663BD5926F8D4CBED95BD4DD026D7A1E9F6EE48EEB247CC7、親PLAN SHAABE9496A5ADA67D85AAC620DF7F9DE863754A3A54EA8C2DCB333A81091030C7Dを全文読了。所有は本書/happy.rs/adversarial.rsだけ。engine/probe/runnerはまだ作らず、親承認前compile/native/verifier0。

ststのfailure-first手順で happy/state/boundary/resource を選択。新別CTSの有限standalone E2Eであり後付けunit testではない。型/並行/外部環境障害は今回private逐次状態機械に非該当。基礎検証/動的分類は親の第二段階単一入口へ延期する（第一段階の実行禁止を優先）。既存soft CTSの成功を新cutの成功へ転用しない。

先行fault一覧：価格型u64/Q8正規化/一次fractionの相違、prefix1価格非zero、class/history/path alias、LSB順/6階層/depth5葉の変更、1bit penaltyを1として足す、同点split、prefixごとの別cut、当該観測を先に利用する予測、6next計算前の部分mutation、raw/CAP/score加算overflow、兄弟sumまたはpenalty加算overflow、snapshot再利用/score改変を受理、予測でstate変更、CAPちょうど予測拒否または更新受理、cold/reset/分布切替履歴違い、rootbestを実際の逐次予測lossと同一視、oracle/helper共有による自己確認、whole dumpをdigestへ代替、finite大配列をfixed inputまで保持する。

仮moduleは crate::engine::{Cts,NodeState}、crate::prices。APIは親PLAN通り、new(5)、prefix/mixed、observations/capacity/same、primary_audit限定dump/seed。seedは合法indexを使う非fallibleprivate診断操作と仮定。Cloneは新API要件にしない。

happy：初期6class×k1..4 uniform CDF/read-only24、正規化域16384..32767の一次PRICES独立式比較16384件。class0 k4 child0123循環128events、class1 prefix1/2/3/4を交互に32events（後半はchild分布変更）。別raw/own/best/split配列、独立指数/一次fraction、除算/剰余LSB path、全6class再帰best/splitを各event後再計算してdump全8190node/history/obsを直接比較。予測は更新前cutに沿った1nodeのratioKT全CDFと1e-12で比較。実逐次選択f64 loss/選択Q8価格と終端rootbest Q8を別fieldへ保存し、regret等をassertしない。全葉split=falseと切替が起こるclass0を検査。fresh Ctsでcold/reset確認。同点leafの人工cached-score fixtureも別分類する。

adversarial：depth0/4/6、class6/k0/k5、k4child4/MAXとk1child1、自然staleとaudit score改変stale、depth5 rawCAP更新拒否/rawCAPover予測拒否、classCAPexact予測可/更新不可とclassCAPover、深いown overflow、兄弟sum overflow、penalty overflow。各拒否前後dump全raw/own/best/split/history/obsとsame(mirror)を検査。CAPexact到達更新1件は正常成功と拒否件数を分離。audit seedによるCAP/score不整合はprivate人工stateであり、実入力からの到達可能性を主張しない。

有限配列worst概算：engine8190*40=327600、oracle raw/own/best/split8190*(16+8+8+1)=270270、dump8190*40=327600、whole-state mirror327600、比較用第二dump327600とVecinline/価格表65536/小配列を足して2MiB未満。正常/異常を逐次実行し全oracle/dump/mirrorを各run終了でdrop、event Vec/trace保存なし。将来fixedphase64MiB/model32MiB/WSprivate各160MiB、source300KiB/EXE1MiB/report256KiB/output8MiB/free5GiBを維持する。これらは見積りで強制quotaや実peak測定ではない。

第一段階完了は3file保存/非書込構文確認/編集停止READY。PASS未宣言、第二段階は別許可。旧source/report/dirty/製品/wire/API/version/x86/Git/external/delete変更なし、追加委任なし。価格/penalty/depth/cut policy一設定、事後routing/sweepなし。実coder/frame/速度/portable/採用/総合goal達成を主張しない。

履歴は原CTS同様u16全16bitをwrapping shift/childで保持し、dumpで全16bit比較する。pathだけ下位10bit。finite期待数はreadonly24/価格16384/観測160/全node1318590/確率640、unsupported depth3、state拒否15（全state15）、CAPexact成功1。class1分布切替は同classのevent16後であり全160eventの16後ではない。own/4子sumはu64、初期own0にleaf tagは足さない。
