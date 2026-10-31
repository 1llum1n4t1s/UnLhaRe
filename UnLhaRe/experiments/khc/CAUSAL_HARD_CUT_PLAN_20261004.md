# hard-cut tree：有限E2Eを先に固定する実装契約

QUESTION SHAFA4803158022EF3F663BD5926F8D4CBED95BD4DD026D7A1E9F6EE48EEB247CC7。全prefixイベント共通cut、Q8一次価格/penalty256/depth5固定の一候補、事後event routing/sweepなし。元CTSと同値ではなく、別予測アルゴリズム。cached更新O6のreadonly設計監査は成立、regret/圧縮率/速度は未測定。

第一段階は新causal-hard-cut/のFAILURE_PLAN/happy/adversarialだけをworker-highが所有。親が全文確認して停止返却を受けるまでengine/probe/runnerを書かない。有限E2Eはunit testではなく後続単一diagnostic CLI内の先行工程。

private APIを固定：Cts::new(depth), predict(class,k)->Snapshot, observe(&Snapshot,child), observations()->[u32;6], capacity_bytes(), same(&Self)。Snapshotのprefix()/mixed()は原pool接続と同形。NodeState {raw:[u32;4],own:u64,best:u64,split:bool}はCopy/Eq/Debug。primary_audit cfg限定audit_dump()->Dump{nodes:Vec<NodeState>,history:[u16;6],observations:[u32;6]}とaudit_seed_class/nodeは有限oracle/tamperだけ。snapshotのstateは外部公開しない。原Modelのframe_audit cfgは無効にする。

有限fixtureは別raw/own配列と別再帰full-treeで8190nodesを各eventごとに照合する。oracle価格は既存PRICES呼出しでなくlog_Q8の指数/一次fraction式を独立評価し、historyは除算/剰余で構築する。全raw/own/best/split/history/observationsを直接比較、digest代用なし。予測時点cutの選択nodeとCDFを確認し、観測後cut変更を当該予測へ遡及しない。mixed prefix1のcost0/count/history更新、cold/resetと分布変化、同点leaf/depth5 leaf、CAP/scoreoverflow/stale/latepath拒否後whole state不変を先行定義。実hard-cut lossと終端best scoreは別物。

第二段階のengine/probe/runnerは第一段階承認後に別指示。直接参照する凍結Model SHA A5C1BD1B5BECBC62628CEE625F66A1259D8942207318BC029D9934895E090732、KT/vector/pathの旧float_cts SHA A7E0DEB3124F9A317F1B487AA07F3BBFC4EB82409BA29E734FB24FF1C048A11F、prices SHA8AA6FA66C13BF11A9D0792E35D67A16D541AB28FE646C2B187A5B968437F66C1。元pool/math/hashcountsを編集しない。新scopeのprimary型だけ交換。fixed input一read/BWT/Front一walk、全Meta/class/count/合法mixed CDF、実entropyを独立再集計して費用screen<=483599を確認する計画。先生の終端entropy/digest一致を新モデルへ要求しない。

予算はsource300KiB、EXE1MiB/report256KiB、生成8MiB、最低空き5GiB。primary8190nodes×実sizeof<=40なら327600B、価格静的表65536B＋inline/transaction/oracle全体を容量式へ計上。finite dump/oracleをfixed input前に破棄し、全eventtrace保持禁止。原Model count/weight/mathのsource構造上固定配列を根拠にbase16MiBの保守枠、primary1MiB＋tree/scratch各64KiB＋allocator4MiBでmodel32MiB未満を見積もる。Vec実capacityとsource上限の根拠を区別し、固定phase64MiB/BWT別141598926B/WinAPI WSとprivate各160MiBを確認する。

rustc1.98.1 edition2024 opt3/thin/CGU1/unwind/overflowyes/debug0/DEBUG:NONE、primitive_audit+primary_auditのみ、compile60/native120秒の単回を親が実行。source/tool/input/旧証拠/先行fixture before/after/live pin、unused output必須。失敗を記録して同条件再起動せず、size未達なら実coder/速度へ進めない。

scope六観点：PerformanceはKT全vector/soft mixture/posteriorの削減、Normalizerは原primitive/pool/math直接参照、Hardeningは6nextのpreflight/whole-state拒否、Testerは別全tree有限oracle、Modernizer依存不変、Cleaner原証拠保持/traceなし。Asyncはsnapshotとoracle解放、Intel現時点外部仕様不要、Startup製品不変で非該当。stage/commit/push/API/version/x86/公開/deleteなし。全固定size/encode/decode/same resource/quiet/warm9/holdout/category/完成書庫metadata/API/4nativeの総合GOALはactive・未達。
