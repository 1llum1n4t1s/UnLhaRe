# CTS sealed snapshot: 数値同値・拒否契約・容量の事前契約

## 対象と完了条件

7-Zip超えの全体目標は維持する。本段階は非公開研究候補で、KT64のobserve内の二重predictを安全なsealed witnessで除く。同じ圧縮出力・復元・拒否理由・拒否時の全状態無変更を維持し、同一プロセスABBAで速度を比較する。正式速度574.5624ms未満、機械CPU15%以下、holdout/categories、4 native環境、製品/API統合は本段階では達成扱いにしない。

所有者: 親は本契約・採否・結果文書と実行、worker-high一人は新規 `quaternary-cts-sealed/` 8ファイルだけ。旧ファイル、製品、manifest、Git stage/commit/push、外部書込み、x86互換版は変更しない。コードを書く前に `FAILURE_PLAN.md` を作成し、E2Eで検証する。既存の数値式・履歴・深さ・tree・pool・wireは凍結。

## 前提証拠

KT64契約SHA: `12C7F578C902D58CEF8438022513DFA63F5A587410C1BB55AD8FDDEC83E87167`。
KT64結果SHA: `F7201905871A5B87314E232D0407A4C74B1A349C16B18CE7547E383D4CCC5DFB`。
KT64 report SHA: `C88FBE8B6FD30B68D013329C3A34D7BEA09A456129F5D06DBF9AF1A72959398B`。
KT64 integer_cts SHA: `90533959E33165C93752D67F0A6B7E8C925F10A9E6AFEE1E03D60F4F25E7D52B`。
KT64 model SHA: `5A69F5A19035A18489D59DF82FD2DBFB423817CCF16414888F2C45BE35271889`。
KT64 new_wire SHA: `C49EA2593C42A0899E9A50D7E8F59365163F014D4F6CBEE772559385DCC77838`。
固定frame: 474730B SHA `9867AB88CD27AE48174C9C1E9FAC65BEEE6D95C95BDE8C53DB2F0E988653BFAD`。
固定input: 2811006B SHA `18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76`。
新しいrunnerは旧KT64 reportの全60source identitiesと既存basisを検証し、旧証拠へ書込まない。source byte/SHA/mtimeを開始終了で照合する。今回の新規sourceも固定して同様に照合する。

## 候補方式と反証

`Snapshot` はRawSnapshotを再公開するaliasではなく、privateフィールド `visible: RawSnapshot` と `certified: RawSnapshot` を持つ新規非公開研究型。private constructorはCts.predictが成功した値だけを封印する。安全なRustからcertifiedを構築・変更・参照できる公開API、Default、Deserialize、from-rawは追加しない。Clone/Debug/Eqは可。Deref/DerefMutはvisibleのみとし、現在の読み出し・監査でvisibleを変更できるがcertifiedは不変とする。unsafeは追加しない。

predictは従来同様pure &selfで、共有cache/nonce/pending state/owner IDを導入しない。予測後のpool失敗もCTS状態を変更しない。複数のpredict、clone、同じ数値stateの別Cts由来tokenも従来通り扱う。公開製品Rust/C/.NET APIは変更しない。この研究型は旧RawSnapshot aliasとのRust source互換性がないことを明記する。

observeの初期guardと理由順は旧実装そのまま: prefix、class/child、tokenとcurrent observations >=CAP。次にvisible.class/prefixを使って現在のstateをgatherする。predictのclass観測guard、node index、leaf(depth8 weight Q/2)、各level昇順のweight<=Qと全4raw和<=CAPの順を維持する。後方に不正nodeがあっても先にsnapshot不一致を返さない。全部の現在state guard後、現在のclass/prefix/path IDs/history/observations/raw/weightsとvisibleを完全比較する。不一致は `stale or modified snapshot`。causal stateが一致し、visible==certifiedも完全一致する通常経路だけderived再計算を省略する。causal state一致だがvisible!=certifiedの場合は旧self.predictとvisible全体のexact比較へフォールバックし、現在の予測と完全一致する改変snapshotは旧と同じく受理する。不一致は旧と同じ理由で拒否する。fallbackの比較はRawSnapshot visible同士であり、certifiedを含むToken Eqを旧Snapshot Eqの代用にしない。

このfallbackは必須。旧方式は「一度でも改変された値」を無条件拒否する契約ではなく、「現在のpredictと一致しない値」を拒否する契約である。例として初期stateのsnapshot.classを同じ数値stateの別classへ変えるだけでも旧方式は受理する。valid class redirect、prefixとderived一式の合法交換、現在stateへのvisible一式交換の旧新受理同値を先に検証する。通常利用の速度を優先してこの互換性を切り捨てない。

合法raw、合法weights、prefix1..4では旧predict_kernelが失敗しない理由を結果で説明する: 正のKT mass、全4raw CAP、active D<=2CAP+4、product<2^55、正のQ-normalized vectors、Q² mixture mass、u128内の積、Hamilton余り上界、正のmixed。これによりderived kernelを再計算せずとも旧guard理由を維持できる。成功後はupdate_kernel・全9node準備・commit順を変更しない。

仮説: 毎branchのCTS予測9KT+8mixtureが2回から1回に減り速くなる。反証: exact出力・全state・拒否理由の不一致、または同条件ABBA候補平均が旧方式以上なら不採用。二重snapshot copyとサイズ増加を計測し、速度改善を先験的に断定しない。depth変更・数値近似・hash certificate・単純guard省略は比較案から除外する。

## E2Eと診断の固定条件

1. standalone `compare-snapshot`: 複数class/prefix/child/history、合法境界、CAP-1→CAP、nodeCAP拒否、stale、derived全種類・raw/weight/ids/history/observations/class/prefix改変、invalid current state、dual-invalid guard優先順、clone/multiple prediction、別Cts同stateで旧新を比較。成功step後は全nodes/history/observationsを直接比較、拒否では旧新のexact reasonを比較して各before/after全state同一を直接比較する。固定seed・固定件数をFAILURE_PLANに先記し、結果は件数/digest/上限付き失敗のみ。
2. 独立CLI selfcheck: 凍結normal14とplain/canonical全byte比較、malformed30のexact reason、model14名/16 assertions、CAP1、CRC fixtureを再利用する。旧model numericalbodyは変更しない。
3. profile: same binaryでold KT64/new sealed/new sealed/old KT64のABBA4encode、候補decode1。固定input/baselineは各1回読込み、各frame474730B全byteとbaselineを直接比較してdrop。decode2811006B全byteとinputを直接比較してdrop。normal selfcheckのcanonicalとfull profileを区別し、full canonical再実行はしない。内側timerなし、warmup/repeat/再試行なし。elapsedはencode/decode callの前後だけ、stats formatting/比較/JSON/dropを含めない。
4. 固定full stats: frame/header/payload474730/281/474449、CRC433441561/3589341169/1741345118、runs889227/primary1762795/alphabet257、rank/length889227、escape742、branches2725772/1099568、grammar58735a2b7383d755、base-pool9128444225deabce、classes[889227,620240,1216305,889227,64372,145969]、CDF3788636.714502990(±1e-4)。すべてのrunで検証する。
5. コンパイル一回: 凍結rustc1.98.1、edition2024/opt2/overflow checks yes/panic abort/debug0/DEBUG:NONE、frame_audit/primitive_audit。runnerのnonExecute構文・importグラフ・pin・容量を親が先に確認した後にExecuteは一回。各CLI120秒・stdout/stderr各64KiB上限・失敗時kill/dispose・raw JSON保存後validate。全3CLIのstderrとexit、EXE前後identity、source前後identityを保存する。正式CPU値とchild processor時間を混同しない。

## 容量と保存

出力先 `UnLhaRe/build/khc-quaternary-cts-sealed-20261003`。8MiB上限、開始/終了guard、空き5GiB+予算を確保。生成前にEXE1MiB+report512KiB=1572864B予約をscalarで確認。最終EXEとreportのみ残す。入力/frame/復元のdisk copyなし、Cargo target/cacheの新設なし、PDB/debug/temp/bak/raw traceなし。固定corpus・旧証拠・共有cache・x86は保持。guardは事前事後確認でOS write quotaではない。

## opop観点台帳（本段階のscopeのみ）

| ID | 担当 | 入口判定と検証 |
| --- | --- | --- |
| Modernizer | 親 | 依存/言語更新は不要、凍結runtime維持 |
| Normalizer | 親 | private seal型とguard順を統一、外部API不変更 |
| Performance | 親 | 再predict除去候補、ABBAで現状を含め比較 |
| Cleaner | 親 | 二重計算だけ対象、旧証拠はbaselineとして保持 |
| Hardening | 親 | certified非公開、exact compare、全拒否順/無変更検証 |
| Tester | 親 | prewritten failure planとstandalone E2E、after-code unit追加なし |
| Async | 親 | 純粋予測・child資源寿命・RAM drop・I/O上限を確認 |
| Startup | 親 | snapshot/EXE sizeと初期化が変わらないか確認 |
| Intel | 親 | 外部仕様変更なし、ローカル数値/状態契約で決着するため非該当 |

全体目標の達成には正式gateが必要。私的候補の改善だけで完了・公開・version更新とはしない。
