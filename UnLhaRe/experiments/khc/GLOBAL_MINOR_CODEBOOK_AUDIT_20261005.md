# global minor codebookの独立反証と採否

temporal_paid_model_audit担当が旧model/bundle/probe/RESULT/report/実bundleの6資料を読み取り調査。編集・compile・native・Git・外部・削除0。親が候補採否と実装を担当する。

旧bundle独立parseは2244葉/470split、k別824/278/1142、uniform931/pure21/raw1292、default root534。旧木に新mode＋largest index＋minor8bits＋834flags＋global u32長とpaddingを適用すると32871bits/4113B。旧10577Bから6464B改善しても、元MDL後token480733＋4113＋side3079＝487925B、gate483599Bに4326B不足。保存費だけの成功予測は反証成立。原free473039Bは無料token469960＋side3079で、MDL後とは別。

候補はglobal class2/5の278nodes/3prefix/history10/depth5を固定、CDF最大値を残余として保存する。uniform/pure厳密一致だけ短符号、他minorを512B固定整数LUTへfloorして復元CDFでDP lossを再計算。leaf費用はdefault3/pure4・5/compact12・21・29bit、全木64511bits/modelで保守142335内。rootdefaultはDP0/oraclewire3/outer1を区別。

LUT一例は先頭64値2..65、残りe6..13/j1..24でmin(16383,2^e+ceil(j*2^e/24))、256値。担当は単調・重複なし・端点を算術確認。floorなら残余が元最大以上でmin2/最大性を保てる。parserはchecked subtraction/min2/largest/index/mode/depth/padding/trailingを必須検査。k3でminor16383を2個並べる不正CDFを、各code有効だけで受理しない。

CDF近似の損失は選択木のΣn_i log2(f旧_i/f復元_i)を符号付きで測る。minor比上限8533/8192の単発約0.05884bitだけでは全loss許容を証明できない。largest改善と各countを含めた実row lossで判定する。上下格子組合せ最大8案も可能だが、親はまずfloor1方式に限定しsweepをしない。

強い制約：静的化対象1362251/3825218＝35.6%、非選択teacher64.4%。元report teacher_models_executed=0/state未検証/frame0。保存teacher lossを足したscreenは実状態・実frame・速度を証明しない。screen通過後の実teacher更新保持・frame往復・actual bytes・CLI速度をGOALから除かない。staticCDF/rANSの性能利益はその工程まで未測定。

LUT512B、Dense13959192/Forest6979896の規模は同じ。元globalのmodel25412546<=32MiB/phase46369880<=64MiB/OS160MiBを維持し実capacityを計上する。新wireは非互換なので旧証拠を凍結、新kindとhashで分離する。

親の採否：floor1/固定global/rootpacket1候補を実装診断へ採る。成功予測・製品採用なし。新DPが4326BとCDF近似損失を取り戻せなければno-go。開始基礎verify-result.ps1はreadonly115組/追加native0/compile0/書込0、494389B未達を確認。全GOAL active。

観点: Performance/Hardening/Testerは上記analyst、Normalizerは実CDF費用のDP統一を親、Modernizerはruntime/依存変更なし、Cleanerは旧証拠用途分離とdiskbundle出力廃止、Asyncはscratch/Forest/packet寿命とfinally解放を親。Intel/Startupは外部現在値・利用者向けbundleを変えないため非該当。
