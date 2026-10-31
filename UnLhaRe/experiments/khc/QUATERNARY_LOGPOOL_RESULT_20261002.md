# 4分岐log-linear pool機会診断結果

判定: 数値・状態・継承比較は成功したが、固定payload機会gateは未達。mixed entropy + 共通escapeは4145740.217873052bits、予算3866504bitsより279236.217873052bits（34904.527234byte相当）大きい。本候補は整数wire/full/正式benchmarkへ進めない。これは実書庫サイズ・速度の測定結果ではない。

前算術mixtureの4272491.963862260bitsから4139804.217873052bitsへ132687.745989208bits（16585.968249byte相当）改善。旧flatの4597717.435179456bitsからは457913.217306404bits（57239.152163byte相当）改善した。予測情報の結合には改善証拠があるが、7-Zip超えは未達。

| 成分 | logpool bits | 前算術mixture bits |
| --- | ---: | ---: |
| rank | 3042949.442600639 | 3159178.789736769 |
| length | 1096854.775272413 | 1113313.174125491 |

固定rate1/256・uniform1/4096・weight clamp[0,2]・初期0.25を事前契約どおり用いた。結果後のparameter変更やgrid、再試行はしていない。全3825340枝の別normalized ln(prob) oracleに対するprobability/loss・15301360gradient・更新weight/countを比較し、終端3182592state値を照合した。最大probability差5.995204332975845e-15、gradient差1.3988810110276972e-13、weight差9.992007221626409e-15で、事前固定tol2e-10*(1+absA+absB)以内。synthetic非対称10予測・中央差分40件、uniform/zero weights/forcedchild1/clamp両端も成功。親も別非対称stateの40中央差分で数式を独立検算した（最大差約1.074e-9、固定FD tol2e-6以内）。

全889227rankの独立positions/cursor oracle、全66049topology cases、各142node/maxdepth7、grammar digest双方58735a2b7383d755、old flat interval1778454件は成功。rank2725772/length1099568枝、prefix件数・rescale378/56/116/7・cold741/36502/123934/105247は前算術候補と一致。4expertのrank/length損失8件とold flat component損失も一致し、poolだけを変えた比較である。clamp下端199744/上端1021回、状態digest dcce505e950e97dc。

親の最終source確認後、opt2/overflowyesを一度compile/runした。rustc1.98.1・bundledpwsh7.6.5、20source/import/compiler/runtime/proof/input識別値のreadlock前後照合とEXE前後照合が成功。親も20識別値+EXEを再hashして差異0。3childの終了code0/stderr空。CLI実行時間は診断全体であり、正式encode/decode速度の証拠には使わない。

保存先 build/khc-quaternary-logpool-opportunity-20261002:

- report.json 19485byte、SHA D84D70C2D64A366C073DEC83E5019DF24C6B34F4538B48435284DEC914C7A320。
- opportunity-o2-yes.exe 241664byte、SHA 22C51EC34DC94430822B1AF17419DB2F3CBA45E2EBB98085B1CB230260104435。
- 保持2file、合計261149byte（約255KiB）、8MiB予算内。frame/restore/rawtrace/table/Cargo/PDB/cacheを生成せず、今回用途終了の一時物はない。証拠は保持する。

source SHA09A858DA1FD1C712D548D53AA580747CF68B74266419A4E1419369961E3B5C6D、runner SHA2AFD5D9E6666FB6237BB287BCDFC6729F1CC02D4FE567231249B2900431D7051、実装前失敗計画 SHA492431F92B9F9FDCC2206E182425ED4156484D053B4FA2A8119808614B7269E7。旧証拠を凍結し、Git stage/commit/push/version/公開/x86/共有cacheは変更していない。

未検証: 整数化primitive、range丸め、実frame、正式速度、holdout/category、4環境native、製品/API。次の仮説は既存のsymbolとrecentの情報を別々に使うだけでなく、その組合せを追加予測として条件付けすること。改善はまだ仮説で、固定gateを維持する。全7-Zip超えgoalは未達・active。
