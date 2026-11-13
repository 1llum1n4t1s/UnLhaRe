# KHC実験の容量と清掃

通常の比較は `run-storage-experiment.ps1` から実行する。4つの既存比較入口
(`compare.ps1` / `compare-solid.ps1` / `measure-internal.ps1` /
`causal-bayes-fast-bwt/compare.ps1`)、版間delta・shared-history・RecordFast screen・候補size probe、all-class-static frame E2E、製品pipeline E2E、storage E2E と `disk-budget.ps1` は、
登録なしの直接実行を拒否する。
Windowsでは呼出元が安全なslugを `$env:KHC_STORAGE_TASK_ID` に必ず設定する。
モジュールは作業先を `%TEMP%\UnLhaRe\work\<task-id>`、保持先を
`%TEMP%\UnLhaRe\TaskArtifacts\<task-id>` に解決する。作成・実行前に絶対パスと既存の親階層を検証し、
reparse point、基点ドライブ不在・書込み不可では停止する。`%TEMP%` はユーザー環境変数TEMP（`[Environment]::GetEnvironmentVariable('TEMP','User')`）を指し、wrapperが子プロセス向けに差し替えた `$env:TEMP` ではない。Cドライブ上でもよい。
新しい `WorkDirectory`（`run-<GUID>`）と全子プロセスのTEMP/TMP・ログ・検証出力はタスク作業先以下、
復元ZIP・台帳・receiptなどの保持証拠はタスク保持先以下へ置く。
旧 `build/`、旧CドライブのTemp/TaskArtifactsは読取専用の履歴として残し、容量計測には含める。共有保持root（コード上は `%TEMP%\UnLhaRe\TaskArtifacts\storage-lifecycle` に解決される）も読取専用として扱う。基点変更前の記録は `<作業フォルダー>\TaskArtifacts\UnLhaRe\storage-lifecycle` などの旧配置にあり、新しい基点へは移行していない。新しい清掃台帳はtask別rootだけに登録する。
以下の実行例は最初に設定した同じtask IDと `$khcStorageRoot`（`%TEMP%\UnLhaRe`）を引き継ぐ。新task IDや別rootを固定枠の回避に使わない。

`causal-row-copy-spatial-bits/run-e2e.ps1` は固定ptt5のcopy＋literal空間bit実験専用。
`-MaxRunMiB 5 -TimeoutSeconds 300` で、standalone rustc・有限正常/悪性E2E・既存KRS2の
完全frame比較を同一runへ収める。lifecycle1GiBと最低64entryの事前受付を必須とし、
不足時は停止する。初回work実測2,668,546byteに基づき、親の指定で7MiBから5MiBへ下げた。
製品統合や追加benchmarkは行わない。保全・Prunlet段階清掃は通常経路と同じ。

`product-spatial-e2e.ps1`は製品KCS1 revision 7／KRS3 revision 8の有限correctness E2E。
ビルド済みCLIと`khc_spatial_e2e` exampleを渡し、`-MaxRunMiB 5 -MaxEntries 64 -TimeoutSeconds 300`で
登録する。約1MiBの固定合成source、API/CLI作成・一覧・検証・展開、KRS3採用とKHC1 fallback、
byte/SHA復元、破損拒否・既存出力保持、revision 1〜7の読込を確認し、少量の正常・破損書庫とJSONを
同一runに保持する。benchmarkは行わない。Cargoは引き続き`run-serial-cargo.ps1`を通す。
既存Canterbury full product E2Eの18MiB/81entry下限は変更しない。

```powershell
$env:KHC_STORAGE_TASK_ID = 'khc-20261019-example'
# 作業・保全の基点。wrapperが差し替える $env:TEMP ではなく、ユーザー環境変数TEMPを使う。
$khcStorageRoot = Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User')) 'UnLhaRe'
$taskWorkRoot = Join-Path (Join-Path $khcStorageRoot 'work') $env:KHC_STORAGE_TASK_ID
$cargoRoot = Join-Path $taskWorkRoot 'cargo'
$parameters = @{
    LabPath = 'C:\path\khc_lab.exe'
    SevenZipPath = 'C:\Program Files\7-Zip\7z.exe'
    InputFiles = @('C:\path\small-input')
    Repeats = 1
}
& .\experiments\khc\run-storage-experiment.ps1 `
    -ScriptPath .\experiments\khc\compare.ps1 `
    -ScriptParameters $parameters -MaxRunMiB 16
```

## SpatialMdl revision-9 finite E2E

Revision 9 correctness is checked by `examples/khc_spatial_mdl_e2e.rs` through the registered
`spatial-mdl-e2e.ps1` entry point. The fixed development fixture is the pinned `input/ptt5` member
from recovery ZIP `<作業フォルダー>\TaskArtifacts\UnLhaRe\storage-lifecycle\runs\8a849a3267954242bcd8424b93526176\recovery.zip`
(ZIP SHA-256 `882e7108870c3de5d20de6e87ffc89f390c5d34630930aef73baed9171557f75`; member 513,216 B,
SHA-256 `0ec3a75089bb52342813496b17e51377bc9eba3cb519a444d67025354841d650`). The runner extracts
only that member into its registered work directory. The direct block-choice matrix uses ptt5; the
API archive uses four synthetic files (including a two-block file), while the CLI source uses the
pinned ptt5 member and `short.bin` to exercise both actual-input selection and the MDL fallback.
The E2E covers deterministic exact-frame selection and tie-to-MDL behavior; empty, tiny, skewed,
text-like, random, ptt5, and block-boundary inputs; API and CLI create/list/test/extract with complete
byte/SHA checks; KCS1 and default-MDL
fallback family enforcement; rejection of corruption, truncation, trailing bytes, unknown revisions,
foreign KRS1 frames, and non-MDL KHC1 LZ fallback; no-replace behavior; and revisions 1 through 8.
This is a correctness-only run, not a performance benchmark or a 7-Zip comparison. The source/script
hashes must be preregistered before build, and the two Release executable hashes must be appended
before E2E execution. Use one run only; a failure is a no-go, not an invitation to repeat the same
condition.

```powershell
$env:KHC_STORAGE_TASK_ID = 'goal-restore-20261019'
& .\experiments\khc\run-serial-cargo.ps1 -TransientMiB 256 -CargoArguments @(
    'build','--locked','--offline','--release','--target','x86_64-pc-windows-msvc',
    '--bin','unlhare-cli','--example','khc_spatial_mdl_e2e'
)
$env:KHC_STORAGE_TASK_ID = 'goal-restore-20261019'
Import-Module .\experiments\khc\storage-lifecycle.psm1 -Force
$taskPaths = Get-KhcStorageTaskPaths
$cargoRoot = $taskPaths.CargoTargetRoot
$cli = Join-Path $cargoRoot 'x86_64-pc-windows-msvc\release\unlhare-cli.exe'
$e2e = Join-Path $cargoRoot 'x86_64-pc-windows-msvc\release\examples\khc_spatial_mdl_e2e.exe'
Get-FileHash -LiteralPath $cli,$e2e -Algorithm SHA256
$parameters = @{
    InputRecoveryZip = '<作業フォルダー>\TaskArtifacts\UnLhaRe\storage-lifecycle\runs\8a849a3267954242bcd8424b93526176\recovery.zip'
    KhcExecutable = $cli
    KhcExecutableSha256 = '50952a6e7781800b946f85a7493bea7ca0923b5a974f34db1ba2baf32d1de6e3'
    E2eExecutable = $e2e
    E2eExecutableSha256 = 'd3a70fdfbedc9017e7a1c65f880b6f593c277f0eb423d59634ce26a84aff3c2f'
    ChildTimeoutSeconds = 240
}
& .\experiments\khc\run-storage-experiment.ps1 `
    -ScriptPath .\experiments\khc\spatial-mdl-e2e.ps1 `
    -ScriptParameters $parameters -MaxRunMiB 5 -MaxEntries 64 -TimeoutSeconds 300
```

The command and executable hashes above are the historical revision-9 run record. The registered
entrypoint and E2E source were later extended for revision 10; do not replay the old command. The
current fixed capacity and new source/build pins are recorded in the revision-10 section below.

| 対象 | 固定枠 |
| --- | --- |
| 既存の `build/` + 旧Cドライブの全 `Temp/Codex/UnLhaRe/`・全 `LocalAppData/Codex/TaskArtifacts/UnLhaRe/` + 全 `%TEMP%\UnLhaRe\work\`・全 `%TEMP%\UnLhaRe\TaskArtifacts\` | 合算30GiB |
| 上記の外部作業先・通常保全（Cargoと登録済み固定保管ZIPを除く、予約を含む） | 合算2GiB |
| 2026-10-13に一度だけ登録した旧buildの保管ZIP | 登録時の実file長固定、30GiB枠の内数 |
| 旧 `build/cargo/` + 全タスク作業先の `cargo/`（合算枠の内数） | 合算6GiB |
| 旧Cの共有 `TaskArtifacts/UnLhaRe/storage-lifecycle/` + 共有の `%TEMP%\UnLhaRe\TaskArtifacts\storage-lifecycle` + 全タスク保持先の復元ZIP・台帳・実行記録（内数） | 合算1GiB |
| 今回の一時物 | 1〜32MiB、既定32MiB |
| 空き容量 | 5GiB + 今回の一時物/バックアップ予約 |

既存量をbaselineとして除外せず、保全先へ移した分も容量削減として数えない。
上記は重なる内数を示す。全体30GiBでは各fileを一度だけ数え、タスク作業先配下のCargoを
通常外部2GiBへ重ねて加算しない。新しいtask IDを選んでも旧C・全タスクの使用量と予約は合算する。
2026-10-13の明示依頼による旧buildの保管だけは、外部KeepRoot直下の
`build-retirement-retention.json`（schema 1の単一登録、32KiB以下）で固定する。
登録済みの `build-retirement-*/build-snapshot.zip` の実容量だけを通常外部2GiBと別に計測し、
外部合計・全体30GiBには含める。判定は旧Cと全タスクを合算した
`外部作業先（Cargo除外） + Keep + reserve <= 2GiB + 登録ZIP実容量`。
登録容量は12GiB以下、正規絶対パス・リンクなし・SHA-256形式・実容量・更新時刻を確認し、
不一致や増加は停止する。ZIPが存在しなければ保管使用量は0となり通常2GiBへ戻る。
実験ごとの登録追加や一般的なbaseline除外には使わず、既存登録を上書きしない。
容量出力は `external_regular_bytes` / `external_cap_bytes` と
`fixed_archive_bytes` / `fixed_archive_cap_bytes` を分けて示す。
開始前・実行中・終了後に検査するが、論理file長の走査とsamplingであり、
OSのdisk quota、実際の割当容量、瞬間peakの保証ではない。entriesは開始時の残容量から
schema2では今回のbytes上限Pを2回、固定3MiBを引き、1 entryあたり128KiBの台帳予約で導出する
（空directoryも含む、最低64件・最大4096件）。既定では残量から自動算出するが、既知の出力inventoryが
大きいscriptは `run-storage-experiment.ps1 -MaxEntries <上限>` で登録前に明示する。
指定値が固定枠で予約できない場合も、run登録・child起動・work作成より前に拒否する。
既存証拠は自動削除しない。同じ件数を実行中監視・復旧・清掃へ渡す。
相対path512文字、work絶対path200文字も上限とする。
大きい集合をこの枠へ無理に通さず、再実行前に必要量と清掃対象を明示する。

Canterbury11 product pipeline E2Eのentry上限は、`Get-KhcProductPipelineEntryBudget` が固定ケースから導出する。
完了時のwork子孫79件と同時に存在し得る公開staging 2件を加えた `max_entries=81` を登録前に確保し、
E2E本体も同じ計算を再確認する。`max_entries` はwork rootを除く数で、recovery inventoryは `.` を含むため、
完了時80件・stagingを含む上限82件となる。完了inventoryが79件の子孫と一致しなければE2Eを失敗扱いにする。

実験プロセスは実行前にWindows Jobへ入れる。root終了後もstdout/stderrのEOFを最大1秒だけ
待ち、Job内の子孫が残る場合はPID一覧と診断を出して失敗扱いにする。Jobが空でもEOF未確認なら
部分出力を成功扱いしない。終了/失敗/timeout時にはJob内全子プロセスの終了を確認する。
その後、今回のwork全体をZIPへ保全し、全fileのbytesとSHA-256を
照合して、Prunletへ渡す単一の正確な対象を `cleanup-request.json` に記録する。
runnerはこの時点でpendingを返して終了し、削除は実行しない。必要なreportは
`BackupPath` のZIP内に残り、復元手順とSHAは `ManifestPath` に記録される。

通常のschema2（`prunlet-recycle-v6`）では、登録済みの正確な単一work rootを独立照合し、
installed Prunletのdelete preview、`DeletePreview`検証、delete、`DeleteResult`検証、
`Finalize`の順で進める。CLIは `cmd.exe` / `login=false` で直接実行し、
可変のpaths-fileを削除権限の根拠にせず、検証済みの単純な絶対UUID rootをliteralで渡す。
schema6のBin実体にはpurgeを呼ばない。全treeと保護されたoperation metadataの照合を通し、
保護された完了記録にproof/request/ZIP/executableを結び付ける。元root不在は物理容量解放を意味せず、
`disposition=recycle-retained`、`reclaimedBytes=0`としてpayloadとmetadata予約を継続計上する。

以下の4receipt手順は既存schema1の履歴・復旧専用で、新しいschema2には使わない。
legacy Prunletの削除・purgeは必ず `cmd.exe` / `login=false` の直接tool callで行う。
CLI出力を要求記録内のreceipt pathへリダイレクトし、各段階で検証scriptの成功を
確認してから次へ進む。`delete` の成功結果から得たoperationIdだけをpurgeへ渡す。

```cmd
C:\Users\IMT\.local\Prunlet\bin\prunlet.exe --config C:\Users\IMT\.local\Prunlet\config.json delete --dry-run --recursive --paths-file <paths_file> > <delete_preview_path>
pwsh -NoProfile -File .\experiments\khc\storage-cleanup.ps1 -RunId <run_id> -Stage DeletePreview
C:\Users\IMT\.local\Prunlet\bin\prunlet.exe --config C:\Users\IMT\.local\Prunlet\config.json delete --recursive --paths-file <paths_file> > <delete_result_path>
pwsh -NoProfile -File .\experiments\khc\storage-cleanup.ps1 -RunId <run_id> -Stage DeleteResult
C:\Users\IMT\.local\Prunlet\bin\prunlet.exe --config C:\Users\IMT\.local\Prunlet\config.json purge <operationId> > <purge_preview_path>
pwsh -NoProfile -File .\experiments\khc\storage-cleanup.ps1 -RunId <run_id> -Stage PurgePreview
C:\Users\IMT\.local\Prunlet\bin\prunlet.exe --config C:\Users\IMT\.local\Prunlet\config.json purge <operationId> --apply > <purge_result_path>
pwsh -NoProfile -File .\experiments\khc\storage-cleanup.ps1 -RunId <run_id> -Stage Finalize
```

`run_id`と各receipt pathはrunnerのJSONに記録され、operationIdは`DeleteResult`検証結果に
表示される。`DeletePreview`は全tree path/kindの一致と`would_delete`を、`DeleteResult`は
operationId・全件`deleted`・元path不在を確認する。purge preview/applyも同じoperationId、
全file status、bytesを照合し、最後のfinalizeだけが`complete.json`を作る。
Prunletの一時復元copyは今回の実験bytesを予約に加えて容量判定し、applyの成功までpendingを維持する。

未完了runや清掃失敗は次の比較・Cargo開始も拒否する。どの段階でも失敗したら次へ進まず、
別削除経路で迂回しない。親の強制終了では未完了台帳を保持し、再開時に対象・ZIP・receiptを
照合する。pending要求がまだないrunに限り、所有プロセス終了と空の `runs/source/tools` 作業先を確認した場合は
`-Stage RecoverUnstarted` を使い、保全ZIPと要求を作って通常のPrunlet手順へ戻せる。実験開始後に放棄されたrunは、
`-Stage RecoverAbandoned` が所有プロセスと子孫の終了、登録済みinvocation・一意な登録作業先、reparse pointなし、
4096件/512文字以内、登録bytes上限内を個別に照合する。実測bytes・entry数から固定枠と全体budgetを再計算して
収まる場合だけ、既存の部分出力を再実行せずそのまま復元ZIPへ保全し、通常のPrunlet手順へ戻す。
欠落・不一致・部分削除・容量超過は自動復旧扱いにせず、そのrunの証拠を保持する。

復元ZIPや台帳を毎回無期限に増やさず1GiBで止める。既存証拠の自動削除・世代上書きは
行わない。枠到達時は、不要と確定した証拠の清掃を明示的に行ってから再開する。
保持先を変更して枠を回避したり、共有Cargo全体をバックアップへ複製したりしない。

Cargoは `run-serial-cargo.ps1 -CargoArguments <array>` を使う。jobs=1、
`CARGO_INCREMENTAL=0`、CLI `--target-dir` と環境変数を同じ
`%TEMP%\UnLhaRe\work\<task-id>\cargo` へ固定し、中間成果物の `build-dir` も同じ場所へ固定する
（[Cargoの設定仕様](https://doc.rust-lang.org/cargo/reference/config.html#buildbuild-dir)）。
子プロセスのTEMP/TMPも同じタスク作業先以下に限定する。利用者指定の `--config`・jobs・targetの上書きは拒否する。
同じtask内ではCargoを共有し、runごとの別targetを作らない。旧 `build/cargo` へは書き込まない。
serial Cargoは従来のより小さい固定cap 6,175,228,536 bytesも維持し、一時枠は3〜512MiB
（既定14MiB、内2MiBはsamplingのreserve）。版間delta screenはthin-LTO release依存crateの
初回buildが進行中で、単発増加133,920,639 bytesを観測し本体crateのcompile前だったため、
512MiBを要求して2MiB reserve後の有効枠を510MiBとする。既定値や固定capは変更しない。
固定capは旧Cargoと全タスクのCargoを合算して適用し、別taskや別targetへ逃がさない。
以後cacheが固定枠を占めて予約を確保できなければ停止し、共有cacheを自動削除しない。
共有cacheは自動削除しないため固定枠到達時は停止する。

過去の候補専用target、KEEPコピー、固定SHA付きproof、個別清掃スクリプトは履歴資料であり、
新しい通常実行経路ではない。過去proofのSHAを現行guardのSHAに書き換えない。
初回の容量guard導入時には過去27GiBのbuildを削除しなかった。
2026-10-13は利用者が旧buildの清掃と必要資料のZIP保管を明示依頼したため、
102,254ファイル・29,287,693,620 bytesをZIP復元データと全SHA-256で照合し、
5,161,203,815 bytesの `build-snapshot.zip` を外部Keepへ一度だけ保管する。
保管先の `archive-verified.json` を検証証拠とする。台帳の `archive_path` と同じディレクトリの
`Restore-BuildSnapshot.ps1` へ `-ArchivePath`、検証済みタスク作業先以下の新しい絶対パス
`-Destination`（親は既存）、`-ExpectedArchiveSha256` を指定する。
通常は `-Prefix` に元buildからの相対パス配列を渡して必要な資料だけ復元する（省略時は全件）。
清掃は共通手順の台帳・残存確認が完了してから通常の比較/Cargo入口を再開する。
Codexアプリ所有のsession/DBはこの清掃の対象に含めない。

検証入口: `run-storage-experiment.ps1` から `test-storage-staged-e2e.ps1` を実行し、
上記4段階のPrunlet直接tool callと各検証stageを通す。小さい自己生成fixtureの復元ZIP、
Prunletの削除・purge、finalizeまで確認する。`test-storage-lifecycle.ps1` は旧直接削除実装を
含むため無効化済みであり、実行しない。全Rustビルドや大きい圧縮計測は不要。

Canterbury11製品pipeline E2Eは `product-pipeline-e2e.ps1` だけを登録入口にし、
既存Temp corpusの全11 file・2,810,784 bytes・ordinal名順のbytes/SHA-256 manifestをpinする。
タスク作業先のCargo targetで先にRelease CLIと `khc_pipeline_e2e` exampleを直列buildし、
その二つだけを実行する。KHC作成、全file復元、破損・CRC・cancel・境界・repeat確認の出力と
archive/hashをreportへ残す。実行・復元物は登録workに限定し、通常のPrunlet staged cleanupを完了する。
最大inventoryはRust E2Eの72 entry、pipeline directory、archive・4つのtool log・reportの計79 entryに、
同時に存在する1組のstaging directory/fileと15 entryの余裕を足した96 entry。
runnerはこのboundを登録前に適用し、scriptもrun recordのentry/byte予約を出力前に再確認する。
固定1GiB台帳枠に96 entryと18MiBのwork bytesを同時予約できない場合、既存証拠の削除や実行ごとの一時的な上限変更で回避せず開始前に停止する。

```powershell
$source = (Join-Path $khcStorageRoot 'work\<task-id>\canterbury-corpus-20261015\files')
& .\experiments\khc\run-serial-cargo.ps1 -TransientMiB 256 -CargoArguments @('build','--release','--target','x86_64-pc-windows-msvc','--bin','unlhare-cli','--example','khc_pipeline_e2e')
& .\experiments\khc\run-storage-experiment.ps1 `
    -ScriptPath .\experiments\khc\product-pipeline-e2e.ps1 `
    -ScriptParameters @{ SourceDirectory = $source; ExpectedSourceManifestSha256 = 'bb63b0d70713c9aefa681347eaf99fb891d59f45923e009ad0deadc9ec9fc438' } `
    -MaxRunMiB 18 -MaxEntries 96 -TimeoutSeconds 900
```

版間delta候補screenは次の入口から実行する。`putty`でPuTTY Plink 0.82→0.83を開発用に
比較し、その後固定手法を`7zr` 24.09→25.01のholdoutへ適用する。両方とも基底版を含む
完全な2-file費用を7-Zip 26.04のsolid archiveおよびzstd `--patch-from` と比較する。
配布物、展開したCLI、圧縮物、JSON結果は登録work内だけに置く。decode各CLIのstdoutは2MiB
上限でメモリcaptureし、展開ファイルは作らない。runnerがCargoの
shared targetを含め開始前・終了後の容量を検査し、最後に通常のPrunlet staged cleanupを行う。

```powershell
& .\experiments\khc\run-storage-experiment.ps1 `
    -ScriptPath .\experiments\khc\version-delta-screen.ps1 `
    -ScriptParameters @{ Dataset = 'putty' } -MaxRunMiB 16 -TimeoutSeconds 1800
```

出力されたrunをSTORAGEのPrunlet 4段階で完了するまで、次のscreen・比較・Cargo実行へ進まない。
`7zr` runでは24.09のrelease APIにupstream digestがないため、公開assetのURL/サイズと取得後の
local SHAを分けて記録する。KHC deltaは当面1MiB以下の二つのnamed memberに限定し、
同じ旧版をarchiveへ含める。patchだけを7-Zipの2-file archiveと比べない。
版間screenは3回計測を維持し、各回のサイズ・SHA-256を記録するが、決定性を確認した圧縮物は
最後の1組だけ保全する。7-Zipは計測の合間に前回archiveのmemberを空に戻し、その処理時間を
encode計測から除外する。

版間screenは `-ScriptParameters` の `ToolCacheZip` に、既に完了・検証済みの同じTaskArtifacts内の
`recovery.zip` を指定できる。screenは隣接する `recovery.json` とZIP内の過去reportを照合し、
7-Zip 26.04 x64 / zstd 1.5.7 の実行ファイルと7-Zipライセンスを今回の登録workへコピーする。
コピー後も各SHA-256を再検証し、参照した復元ZIPとコピー一覧を新reportへ記録する。
配布アーカイブを重複保持せずに済む。2026-10-15の利用者許可により、既存証拠を削除せず候補追試を継続できるよう固定保全枠を128MiBから160MiBへ拡張した。2026-10-16は確認往復を避ける利用者指示に基づき、KRS3 screenと製品E2Eを順次実施する予約分として160MiBから224MiBへ拡張した。2026-10-17は容量拡張確認の往復を避ける利用者指示に基づき、実験保全と複数categoryのholdout準備に余裕を持たせる固定枠として224MiBから1GiBへ一度に拡張した。Cargoの固定6GiB枠・外部Tempと通常保全の合算2GiB枠・全体30GiB枠は維持する。今回の一時容量枠は個別に指定する。
利用例（`<run-id>` は完了済みの保全run IDへ置き換える）:

```powershell
& .\experiments\khc\run-storage-experiment.ps1 `
    -ScriptPath .\experiments\khc\version-delta-screen.ps1 `
    -ScriptParameters @{ Dataset = '7zr'; ToolCacheZip = (Join-Path $khcStorageRoot 'TaskArtifacts\storage-lifecycle\runs\<run-id>\recovery.zip') } `
    -MaxRunMiB 7 -TimeoutSeconds 1800
```

RecordFastの候補選択screenは `record-fast-screen.ps1` を入口にし、`BinaryAdaptive`完全frameと
`RecordFastTrial`を同じ入力で比較する。入力は登録workへコピーしてSHA-256を検証し、決定性と
往復はベンチ本体が各方式・各反復で確認する。KRS2はschedule込みで厳密に小さい場合だけ
選択として記録し、fallbackはBinaryAdaptiveとサイズ・CRCが一致しなければ失敗する。
これは候補選別であり、7-Zipに対する性能優位の証明ではない。

```powershell
$inputs = @('C:\path\7zr-24.09.exe', 'C:\path\7zr-25.01.exe')
& .\experiments\khc\run-storage-experiment.ps1 `
    -ScriptPath .\experiments\khc\record-fast-screen.ps1 `
    -ScriptParameters @{ InputFiles = $inputs; IncludeBuiltinSynthetic = $true; Rounds = 3 } `
    -MaxRunMiB 8 -TimeoutSeconds 1800
```

KRS3の開発用block screenは `record-adaptive-screen.ps1` を使い、KRS2 `RecordFastTrial` と
KRS3 `RecordAdaptiveTrial` を既知Canterbury `ptt5` の同一513,216-byte blockで比べる。
`khc_record_fast_bench` はReleaseで `run-serial-cargo.ps1` 経由にbuildし、各方式3 warm-up後に
3 encode/decode sampleを採取する。実行順を3 paired batchで交互にし、frameの長さ・SHA-256・
入力復元とOS peak working setを記録する。KRS2 baselineが46,202 B / CRC32 2,710,226,762と
一致しない場合は停止する。KRS3のfallback、64MiB peak working set超過、またはblock frameが
42,127 B以上なら製品archive統合へ進まない。42,127 B未満でもこれはouter overhead 72 Bを据え置いた
開発上の見込みに過ぎず、実書庫の測定が必要。実行前に新しい5×1秒CPU sampleが全件15%以下であることを
確認し、固定容量・入力hashのpreflight後、以下の完全一致で登録する。CPU gateが崩れた場合は同一負荷で再試行しない。
記録済みRelease bench `build/cargo/release/examples/khc_record_fast_bench.exe` はRust 1.98.1でbuildされ、
SHA-256 `abcf5cbd839f059a8f633634eb1bc2c0cc49fdef2bd6b3f39e5168a6be019bbb`。これは履歴の識別値であり、
新しいbuild先はタスク作業先のCargoとなる。screenは別hashを拒否する。

```powershell
$cargoArguments = @('build', '--release', '--example', 'khc_record_fast_bench')
& .\experiments\khc\run-serial-cargo.ps1 -CargoArguments $cargoArguments

$runId = '8a849a3267954242bcd8424b93526176'
$recovery = "$khcStorageRoot\TaskArtifacts\storage-lifecycle\runs\$runId\recovery.zip"
$parameters = @{ InputRecoveryZip = $recovery; InputRecoveryZipSha256 = '882e7108870c3de5d20de6e87ffc89f390c5d34630930aef73baed9171557f75'; Rounds = 3 }
& .\experiments\khc\run-storage-experiment.ps1 `
    -ScriptPath .\experiments\khc\record-adaptive-screen.ps1 `
    -ScriptParameters $parameters -MaxRunMiB 5 -MaxEntries 64 -TimeoutSeconds 300
```

RecordFast候補のうち選択が確認された小さな入力だけを、`record-fast-7zip-screen.ps1`で製品書庫として比較する。
KHCは同じRelease CLIでBinaryAdaptive・RecordFastTrialを作成し、7-Zip 26.04の7z/LZMA2と各3回比較する。
反復ごとに方式の実行順を回転し、3方式が各位置を一度ずつ通るようにする。
書庫のサイズ・SHA-256、
KHC revisionとKRS2 frame選択、7-Zipの実効method/dictionary、各書庫のtest・展開、復元byte/SHA-256、
起動込み時間・CPU・OS高水位メモリを記録する。各反復の全成果物はrun内に保持し、同一方式の決定性を確認する。
入力は1〜16ファイル、合計1MiB以下。これは候補の単一データ種別screenであり、他データや総合優位性の証明ではない。
測定前に候補が選択された根拠と入力SHA-256を確認し、通常のPrunlet staged cleanupが完了するまで次の実験へ進まない。
既存の検証済みrecovery ZIPから入力を再利用するときは `InputRecoveryZip`、ZIP SHA-256、
`InputRecoveryMembers` を指定する。指定memberは登録work内へ直接展開し、未登録の一時コピーは作らない。

```powershell
$inputs = @((Join-Path $khcStorageRoot 'work\<task-id>\canterbury-corpus-20261015\files\ptt5'))
& .\experiments\khc\run-storage-experiment.ps1 `
    -ScriptPath .\experiments\khc\record-fast-7zip-screen.ps1 `
    -ScriptParameters @{ InputFiles = $inputs; KhcExecutable = (Join-Path $cargoRoot 'x86_64-pc-windows-msvc\release\unlhare-cli.exe'); SevenZipPath = 'C:\Program Files\7-Zip\7z.exe' } `
    -MaxRunMiB 12 -TimeoutSeconds 900
```

KRS3の製品書庫比較は、先に`record-adaptive-screen.ps1`が同じptt5でKRS3を選び、frameが42,127 B未満となった場合に限って行う。`record-fast-7zip-screen.ps1`へ`IncludeRecordAdaptiveCandidate=$true`を渡すと、既存3方式にrevision 8の`record-adaptive-trial`を加え、BinaryAdaptive・KRS2・KRS3・7-Zipを3 roundずつ順序回転して比較する。KRS3 modeは開発入力の固定ZIP・member・SHA-256以外を拒否し、登録前の外部CPUゲートに加えて測定直前の内部5×1秒CPUゲートを通す。reportにはrevision/frame magic別の選択、完全書庫SHA-256・size、test/extract、byte/SHA復元、時間とOS高水位メモリを保持する。これは同じ既知ptt5のcandidate product screenであり、holdoutや優位性の証明ではない。

```powershell
$runId = '8a849a3267954242bcd8424b93526176'
$recovery = "$khcStorageRoot\TaskArtifacts\storage-lifecycle\runs\$runId\recovery.zip"
$parameters = @{
    InputRecoveryZip = $recovery
    InputRecoveryZipSha256 = '882e7108870c3de5d20de6e87ffc89f390c5d34630930aef73baed9171557f75'
    InputRecoveryMembers = @('input/ptt5')
    KhcExecutable = (Join-Path $cargoRoot 'x86_64-pc-windows-msvc\release\unlhare-cli.exe')
    SevenZipPath = 'C:\Program Files\7-Zip\7z.exe'
    IncludeRecordAdaptiveCandidate = $true
}
& .\experiments\khc\run-storage-experiment.ps1 `
    -ScriptPath .\experiments\khc\record-fast-7zip-screen.ps1 `
    -ScriptParameters $parameters -MaxRunMiB 12 -MaxEntries 64 -TimeoutSeconds 900
```

登録runnerはKRS3 modeに対し12MiB/64-entry/900秒の完全一致を要求する。candidate block screenを飛ばしたproduct比較、CPU gate不合格後の同条件再試行、別入力への差し替えをしない。成功しても既知開発入力1件の結果に限る。

固定ptt5の製品比較は `spatial-bits-product-screen.ps1` を登録入口から
`-MaxRunMiB 5 -MaxEntries 64 -TimeoutSeconds 300` の完全一致で実行する。
`ScriptParameters` は `KhcExecutable` と `SevenZipPath` を指定する。入力は既定の検証済み
recovery ZIP（SHA-256 `882e7108870c3de5d20de6e87ffc89f390c5d34630930aef73baed9171557f75`）の
`input/ptt5`、513,216 bytes、SHA-256 `0ec3a75089bb52342813496b17e51377bc9eba3cb519a444d67025354841d650`。
同じZIPを別の保全先で使う場合だけ `InputRecoveryZip` を指定でき、hash/member/サイズは固定する。
KCS1製品revision 7・KRS2製品revision 6・7-Zip 26.04を各1 warmup＋9回測定し、方式順を回転・交互反転する。
各作成・完全decode/CRC検証の直前に総CPU使用率15%以下を取得・記録し、取得不能・超過では停止する。
測定はprocess起動・I/O込みwallとOS peak working set/paged memoryであり、filesystem展開速度ではない。
7-Zip設定は上のRecordFast比較と同じで、実効LZMA2 method/dictionaryも記録する。
書庫は全30個（各64KiB上限）、最終byte/SHA往復の展開は各方式1個だけ、JSONは512KiB上限とし、
入力・最終展開・ディレクトリを含め5MiB/64entry内に収める。全生成物は登録work内だけに置き、script自身は削除しない。
詳細は `spatial-bits-product-screen.json`、stdoutは簡潔な方式別集計。
これは既知の開発入力1件のscreenであり、holdoutや一般的な優位性の証明として扱わない。

複数ファイルの共有履歴screenは `shared-history-screen.ps1` を使う。汎用 `group-bench` に
KHSGRP0の1グループを渡し、KHCの完全往復・決定性を確認する。7-Zip 26.04はsolid LZMA2、辞書上限64MiB、
1 threadで圧縮し、archive test後に抽出した各basename・全byte・SHA-256を入力と照合する。
これはサイズと正しさの初回screenであり、時間・メモリ・7-Zipに対する優位性を主張しない。
入力は2〜16個、各64MiB以下、グループ全体64MiB以下とし、次の比較に進む前に通常のPrunlet staged cleanupを完了する。

```powershell
$inputs = @('C:\path\7zr-24.09.exe', 'C:\path\7zr-25.01.exe')
& .\experiments\khc\run-storage-experiment.ps1 `
    -ScriptPath .\experiments\khc\shared-history-screen.ps1 `
    -ScriptParameters @{ InputFiles = $inputs; SevenZipPath = 'C:\Program Files\7-Zip\7z.exe' } `
    -MaxRunMiB 16 -TimeoutSeconds 900
```

`greedy-entropy-bound-screen.ps1`は、完了済みの共有履歴screenの検証済みrecovery ZIPから
`all.group`を再利用し、貪欲BT5パースのフィールド別静的entropy下限だけを一度測る。頻度表と終端費用を
無料にした楽観的下限であり、実現サイズ・速度・メモリ・7-Zip優位性の証拠ではない。測定は
`--dictionary-mib 64 --algorithm beam --beam-width 4 --beam-block 8192 --beam-model current --beam-matches bt5`
のplain BT5条件に固定する。今回の判定線は、
既知7-Zip総量より5%小さい下限が得られたときだけ実装候補の単発probeへ進む。ZIP・manifest・group・
比較reportをSHA-256で照合し、一般の新入力比較や再圧縮は行わない。新しい実験前に通常のPrunlet staged cleanupを完了する。

```powershell
$runId = '995f90e914704cb79936b7013f0c2c0b'
$run = "$khcStorageRoot\TaskArtifacts\storage-lifecycle\runs\$runId"
& .\experiments\khc\run-storage-experiment.ps1 `
    -ScriptPath .\experiments\khc\greedy-entropy-bound-screen.ps1 `
    -ScriptParameters @{ RecoveryZip = (Join-Path $run 'recovery.zip'); RecoveryManifest = (Join-Path $run 'recovery.json'); ExpectedArchiveSha256 = 'd1aa7ebcd0206ff15081e3d4d00c7634accbe2f662e567e1484ec183c3fddcf6'; SourceRunId = $runId; LabExecutable = (Join-Path $cargoRoot 'release\examples\khc_lab.exe') } `
    -MaxRunMiB 12 -TimeoutSeconds 900
```

ASCII digit-runのsize-first pilotは、固定Canterbury開発member `cp.html` に対する一構成だけを試す。
入力はD上の既存保全run `0acc17d780a142dcafe88645a07205a5\recovery.zip` とその固定SHAを
`digit-run-size-probe.ps1` 内で検証する。24,603 Bのmemberをrun work内へ一度だけ抽出し、最大1 MiB blockの
KDR1変換を`BinaryAdaptive`で符号化した完全block frameと、raw inputの完全block frameをサイズ比較する。
候補は5%以上小さく、全E2E安全検査とbyte復元に合格した場合に限って後続評価へ進む。
これは開発用のsize-only pilotで、製品archive、7-Zip比較、時間、最大メモリ、holdout性能の証明ではない。
CPU gateとCPU性能計測は行わない。出力・TEMPは登録runnerのD task領域に限定し、`probe.json`と`result.json`
を必要な再現証拠としてlifecycle保全する。登録枠は3 MiB / 64 entries / 120秒に固定し、entry数は
lifecycle契約の最小値を使う。

```powershell
& .\experiments\khc\run-serial-cargo.ps1 -CargoArguments @('build','--locked','--offline','--release','--target','x86_64-pc-windows-msvc','--example','khc_digit_run_probe') -TransientMiB 256
$taskPaths = Get-KhcStorageTaskPaths
& .\experiments\khc\run-storage-experiment.ps1 `
    -ScriptPath .\experiments\khc\digit-run-size-probe.ps1 `
    -ScriptParameters @{ ProbeExecutable = (Join-Path $taskPaths.CargoTargetRoot 'x86_64-pc-windows-msvc/release/examples/khc_digit_run_probe.exe') } `
    -MaxRunMiB 3 -MaxEntries 64 -TimeoutSeconds 120
```

固定Gear CDCと完全一致file間参照のsize-first pilotは、事前登録済みのPlink 0.82/0.83開発pairだけに対して
`cross-file-dedup-size-probe.ps1` で一度実行する。Rust E2EはA/B/CのKCD1 archiveをmemory内で比較し、
workには固定入力2件と小さな`probe.json` / `result.json`だけを置く。probe childは240秒で打ち切り、外側runnerは
300秒で上限を設ける。build後は実行前にprobe executableのSHA-256を
`RESEARCH_SELECTION_20261005.md`へ追記し、そのpinを確認してからrunnerを開始する。初期source・runner・lifecycle
hashは同ファイルの候補登録に記録する。実行枠は8 MiB / 64 entries / 300秒。サイズ以外の性能計測、7-Zip比較、
holdout評価、製品archive/API変更には使用しない。

```powershell
& .\experiments\khc\run-serial-cargo.ps1 -TransientMiB 256 -CargoArguments @('build','--locked','--offline','--release','--target','x86_64-pc-windows-msvc','--example','khc_cross_file_dedup_probe')
$taskPaths = Get-KhcStorageTaskPaths
$probe = Join-Path $taskPaths.CargoTargetRoot 'x86_64-pc-windows-msvc/release/examples/khc_cross_file_dedup_probe.exe'
Get-FileHash -LiteralPath $probe -Algorithm SHA256
```

```powershell
$parameters = @{ ProbeExecutable = $probe }
& .\experiments\khc\run-storage-experiment.ps1 `
    -ScriptPath .\experiments\khc\cross-file-dedup-size-probe.ps1 `
    -ScriptParameters $parameters -MaxRunMiB 8 -MaxEntries 64 -TimeoutSeconds 300
```

HTMLタグ／本文span分離 `KHT1` のsize-first pilotは、事前登録した開発用 `cp.html` だけで一度実行する。
引用符の内側を無視した最初の `>` で閉じるbyte spanを分類し、タグstream・本文stream・全span descriptorを含む
transform frame全体を同じ `BinaryAdaptive` で符号化する。workには固定 `cp.html` と小さな `probe.json` / `result.json`
だけを置く。子probeは90秒、外側runnerは120秒で打ち切り、登録枠は3 MiB / 64 entries / 120秒に固定する。
build後はprobe executableのSHA-256を `RESEARCH_SELECTION_20261005.md` に追記し、実行前に確認する。
初期source・runner・lifecycle・共通runner hashも同ファイルに記録する。既使用の開発入力でありholdoutではないため、
速度・memory・7-Zip・製品性能・一般性を主張しない。5%以上小さくならないか、全E2Eが通らない場合は再試行せずno-goとする。

```powershell
& .\experiments\khc\run-serial-cargo.ps1 -TransientMiB 256 -CargoArguments @('build','--locked','--offline','--release','--target','x86_64-pc-windows-msvc','--example','khc_html_span_probe')
$taskPaths = Get-KhcStorageTaskPaths
$probe = Join-Path $taskPaths.CargoTargetRoot 'x86_64-pc-windows-msvc/release/examples/khc_html_span_probe.exe'
Get-FileHash -LiteralPath $probe -Algorithm SHA256
```

```powershell
$parameters = @{
    ProbeExecutable = $probe
    SourceArchive = (Join-Path $khcStorageRoot 'TaskArtifacts\storage-lifecycle\runs\0acc17d780a142dcafe88645a07205a5\recovery.zip')
}
& .\experiments\khc\run-storage-experiment.ps1 `
    -ScriptPath .\experiments\khc\html-span-size-probe.ps1 `
    -ScriptParameters $parameters -MaxRunMiB 3 -MaxEntries 64 -TimeoutSeconds 120
```

既知開発入力 `ptt5` で KRS2 の speed-priority を判定する場合に限り、`record-fast-7zip-screen.ps1 -SpeedFrontierStudy`
を使う。候補は revision 6 / `record-fast-trial`、対照は `binary-adaptive`、7-Zip 26.04 x64 の LZMA2 7z
`-mx=1,3,5,7,9 -m0=lzma2:d=64m -mmt=1 -ms=on -mqs=off`（時刻metadata無効）に固定し、5 round順序回転する。
実効method/dictionary、各書庫のhash/size、test、完全byte/SHA復元、起動込みwall time、WorkingSet/paged memoryを記録する。
実行前と各roundの `_Total` CPU 5×1秒sampleがすべて15%以下でなければ測定を中止し、同条件でretryしない。
事前登録のscreen pass基準は研究選定文書に記載する。これは開発用screenでholdoutではなく、passした場合のみAITDCC I–P全件の
独立したheldout実書庫評価へ進む。固定run枠は28 MiB / 128 entries / 900秒で、input、全sample archive、全extract、reportを
登録work内に保持する。外側とchild双方に900秒を指定し、通常のPrunlet staged cleanupが完了するまで次のrunへ進まない。

```powershell
$runId = '8a849a3267954242bcd8424b93526176'
$parameters = @{
    InputRecoveryZip = "$khcStorageRoot\TaskArtifacts\storage-lifecycle\runs\$runId\recovery.zip"
    InputRecoveryZipSha256 = '882e7108870c3de5d20de6e87ffc89f390c5d34630930aef73baed9171557f75'
    InputRecoveryMembers = @('input/ptt5')
    KhcExecutable = (Join-Path $khcStorageRoot 'work\goal-restore-20261019\cargo\release\unlhare-cli.exe')
    SevenZipPath = 'C:\Program Files\7-Zip\7z.exe'
    SpeedFrontierStudy = $true
    SevenZipLevels = @(1,3,5,7,9)
    TimeoutSeconds = 900
}
& .\experiments\khc\run-storage-experiment.ps1 `
    -ScriptPath .\experiments\khc\record-fast-7zip-screen.ps1 `
    -ScriptParameters $parameters -MaxRunMiB 28 -MaxEntries 128 -TimeoutSeconds 900
```

## SpatialMdl revision-9 ptt5 product screen

This is a development-only paired screen for `spatial-mdl-trial` against 7-Zip 26.04 x64
LZMA2. It uses only the previously used Canterbury `ptt5` fixture; it is not heldout and does not
support a general product-performance claim. The preregistered comparison is 1 warmup + 9 paired
rounds with alternating order. Every create and real filesystem extraction is separately timed,
every extracted file is checked against the pinned byte length/SHA, and every archive hash/size is
checked for deterministic repetition. `7z t` / `khc-test` do not substitute for the timed extract.
Each timed operation has a single `_Total` CPU sample immediately before launch and stops if it
exceeds 15%; there is no wait-and-retry. Each child is capped at 30 seconds and 160 MiB peak working
set, with an outer 300-second cap. The screen candidate passes only if all correctness, determinism,
and resource checks pass and the complete revision-9 archive is at least 5% smaller than the
7-Zip archive; otherwise it is a no-go for this candidate/configuration. A pass only earns a separate
review of whether to preregister full heldout evaluation.

The registered work cap is 16 MiB / 96 entries / 300 seconds. It retains all 20 archives and 20
fresh extraction trees. For `U=513,216 B`, archive ceiling `A=65,536 B`, and report cap `R=524,288 B`,
the fixed minimum is `21*U + 20*A + R = 12,612,544 B`; the remaining cap is staging/TEMP margin.
No files are deleted by the screen: clean only through the registered lifecycle and the required
Prunlet protocol. Before registration, record and re-check the complete SHA-256 pins for the screen,
revision-9 sources, CLI, 7-Zip, input recovery ZIP, storage runner, and lifecycle module in this
section and `RESEARCH_SELECTION_20261005.md`.

Pre-run pins (2026-10-19; re-hash all before registration):

| Target | SHA-256 |
| --- | --- |
| `spatial-mdl-7zip-product-screen.ps1` | `3ce500d4115653d340afa5b54f667ff5b89d6e5e19a5d32502344b4d1e23f3f4` |
| `src/khc/mod.rs` / `src/main.rs` | `c3335017f8905364f66d797f992f10ba54a50707116cb224304acc4470ec41fa` / `35ee6bd7a7d222db03f92a1647155c678d752b9a69e793b4749a665fa57c72aa` |
| `Cargo.toml` / `Cargo.lock` | `3b47e50b8e543a5af82617bee4d4bd48ec20fc795a333ba50cbc9e439e0c2fac` / `d8dab69b03805b559440c186ed04c2d0d0ee57eba922306cfa6827bf79985554` |
| Release CLI | `50952a6e7781800b946f85a7493bea7ca0923b5a974f34db1ba2baf32d1de6e3` |
| 7-Zip 26.04 x64 | `95fff19b73eff77c87c0d7bd32822e43fb90dd2932459f962eb532d8dfb6ba53` |
| pinned ptt5 recovery ZIP | `882e7108870c3de5d20de6e87ffc89f390c5d34630930aef73baed9171557f75` |
| `run-storage-experiment.ps1` | `6fe4460a23e0fca7539a73937a6ee54af8b2e9d3935c5d596975f21bc51af2ad` |
| `storage-lifecycle.psm1` | `511ac35885416d0ee7deb6367f2f210d6bda3e71ced3001a590dd90426962ac3` |

Fixed input/tool paths: `<作業フォルダー>\TaskArtifacts\UnLhaRe\storage-lifecycle\runs\8a849a3267954242bcd8424b93526176\recovery.zip`,
`<作業フォルダー>\UnLhaRe\goal-restore-20261019\cargo\x86_64-pc-windows-msvc\release\unlhare-cli.exe`,
and `C:\Program Files\7-Zip\7z.exe`.

```powershell
$parameters = @{
    InputRecoveryZip = '<作業フォルダー>\TaskArtifacts\UnLhaRe\storage-lifecycle\runs\8a849a3267954242bcd8424b93526176\recovery.zip'
    KhcExecutable = '<作業フォルダー>\UnLhaRe\goal-restore-20261019\cargo\x86_64-pc-windows-msvc\release\unlhare-cli.exe'
    KhcExecutableSha256 = '50952a6e7781800b946f85a7493bea7ca0923b5a974f34db1ba2baf32d1de6e3'
    SevenZipPath = 'C:\Program Files\7-Zip\7z.exe'
    SevenZipSha256 = '95fff19b73eff77c87c0d7bd32822e43fb90dd2932459f962eb532d8dfb6ba53'
}
& .\experiments\khc\run-storage-experiment.ps1 `
    -ScriptPath .\experiments\khc\spatial-mdl-7zip-product-screen.ps1 `
    -ScriptParameters $parameters -MaxRunMiB 16 -MaxEntries 96 -TimeoutSeconds 300
```

## SpatialMdlTrial Canterbury11 size-only screen

This is a separate development-corpus size/correctness screen following the revision-9 `ptt5`
screen that stopped at its CPU gate before creating an archive. It uses all 11 pinned Canterbury
files, not heldout data, and collects no timing, CPU, or memory measurements. The candidate is the
revision-9 `spatial-mdl-trial` Release CLI. The strong 7-Zip 26.04 x64 control is 7z/LZMA2 at
`-mx=9 -md=64m -mmt=1 -ms=on -mqs=off -mtm=off -mtc=off -mta=off`.

The run creates two fresh archives per tool, requires byte-identical deterministic repeats, tests
all four archives, extracts all four to separate fresh directories, and compares each result to the
exact 11-file length/SHA manifest. The candidate advances only if its complete archive is at least
5% smaller (`candidate_bytes * 100 <= seven_zip_bytes * 95`); a pass is only a development-data
size screen and does not establish speed, memory, general, or heldout superiority.

The fixed input is `pipeline-e2e/canterbury/` inside
`<作業フォルダー>\TaskArtifacts\UnLhaRe\storage-lifecycle\runs\5e93ed1e99ca4f5ab29d490db421e50b\recovery.zip`
(8,765,120 B, SHA-256 `b74644fac5f89251b15a68db6b2a3bce1bd508c12f0f685a61cd5c96ae1540bb`). Its
11 files total 2,810,784 B and have manifest SHA-256
`bb63b0d70713c9aefa681347eaf99fb891d59f45923e009ad0deadc9ec9fc438`; the source archive stays in
the existing read-only retention location and is not copied into the run. The script extracts only
those 11 pinned members into registered work. Full per-file hashes and the exact gate are in
`RESEARCH_SELECTION_20261005.md`.

The fixed run cap is 32 MiB / 96 entries / 300 seconds. With `U=2,810,784 B`, archive limit
`U+65,536 B`, 20 tool logs each capped at 64 KiB, and a 512 KiB report, the conservative work plus
one archive staging file is `U + 4*(U+65,536) + 4*U + 20*65,536 + 524,288 + (U+65,536) =
30,270,528 B`. The registered disk-budget monitor remains authoritative and fails closed if the
actual usage or lifecycle budget exceeds its cap. No same-condition retry is allowed after any
failure; clean completed work only through the registered Prunlet lifecycle.

Before registration, reconfirm the input, CLI, 7-Zip, revision-9 source, script, storage runner,
lifecycle module, and disk-budget pins below. Run `Assert-KhcStorageBudget -ReserveBytes 72MB`,
confirm no pending run and no target process, then invoke only through the registered runner.

```powershell
$env:KHC_STORAGE_TASK_ID = 'goal-restore-20261019'
$parameters = @{
    InputRecoveryZip = '<作業フォルダー>\TaskArtifacts\UnLhaRe\storage-lifecycle\runs\5e93ed1e99ca4f5ab29d490db421e50b\recovery.zip'
    InputRecoveryZipSha256 = 'b74644fac5f89251b15a68db6b2a3bce1bd508c12f0f685a61cd5c96ae1540bb'
    ExpectedSourceManifestSha256 = 'bb63b0d70713c9aefa681347eaf99fb891d59f45923e009ad0deadc9ec9fc438'
    KhcExecutable = '<作業フォルダー>\UnLhaRe\goal-restore-20261019\cargo\x86_64-pc-windows-msvc\release\unlhare-cli.exe'
    KhcExecutableSha256 = '50952a6e7781800b946f85a7493bea7ca0923b5a974f34db1ba2baf32d1de6e3'
    SevenZipPath = 'C:\Program Files\7-Zip\7z.exe'
    SevenZipSha256 = '95fff19b73eff77c87c0d7bd32822e43fb90dd2932459f962eb532d8dfb6ba53'
}
& .\experiments\khc\run-storage-experiment.ps1 `
    -ScriptPath .\experiments\khc\spatial-mdl-canterbury-size-screen.ps1 `
    -ScriptParameters $parameters -MaxRunMiB 32 -MaxEntries 96 -TimeoutSeconds 300
```

Pre-run SHA-256 pins (2026-10-19; re-hash every item before registration):

| Target | SHA-256 |
| --- | --- |
| `spatial-mdl-canterbury-size-screen.ps1` | `28db2ed65ff254378aaa811fde43ae3017601ca9239a2a30d8b0eac04911e1ba` |
| `src/khc/mod.rs` / `src/main.rs` | `c3335017f8905364f66d797f992f10ba54a50707116cb224304acc4470ec41fa` / `35ee6bd7a7d222db03f92a1647155c678d752b9a69e793b4749a665fa57c72aa` |
| `src/khc/block/mod.rs` / `src/khc/spatial.rs` | `861da675a6eee403e51a7d2130ad80414da765c72a5e37eca6966084067fd748` / `8b508ee1c876c0b581af1bba66cecb0e1b183db3eae31349033fa8a0ec374982` |
| `Cargo.toml` / `Cargo.lock` | `3b47e50b8e543a5af82617bee4d4bd48ec20fc795a333ba50cbc9e439e0c2fac` / `d8dab69b03805b559440c186ed04c2d0d0ee57eba922306cfa6827bf79985554` |
| Release CLI `unlhare-cli.exe` | `50952a6e7781800b946f85a7493bea7ca0923b5a974f34db1ba2baf32d1de6e3` |
| 7-Zip 26.04 x64 `7z.exe` | `95fff19b73eff77c87c0d7bd32822e43fb90dd2932459f962eb532d8dfb6ba53` |
| Canterbury recovery ZIP | `b74644fac5f89251b15a68db6b2a3bce1bd508c12f0f685a61cd5c96ae1540bb` |
| `run-storage-experiment.ps1` | `b68a005dc949f08eba5ec6cea4601a1558da29e269fea2ae81560268c49c7593` |
| `storage-lifecycle.psm1` / `disk-budget.ps1` | `511ac35885416d0ee7deb6367f2f210d6bda3e71ced3001a590dd90426962ac3` / `506e4c68dc05734bc1a0c02bac6f81d4677e0bcffd9b9fa2b7bd67d53319bdcd` |

The same implementation/input pins and the final `STORAGE.md` SHA-256 are recorded in
`RESEARCH_SELECTION_20261005.md` before registration.

## Existing-codec portfolio block-size pilot

This is a size-only development pilot to decide whether revision 10 integration is worth doing;
it is not an archive-format implementation, a speed/memory result, or a heldout evaluation. It uses
the same pinned Canterbury11 input and 7-Zip 26.04 size result as the completed revision-9 screen,
but tests a distinct encoder candidate: choose the smallest complete per-block frame from, in fixed
tie-breaking order, `Mdl`, `SpatialBitsTrial` (KCS1), `RecordFastTrial` (KRS2), and
`RecordAdaptiveTrial` (KRS3). This set includes the revision-9 baseline plus two existing
independent candidates. G32/Delta16 are omitted due to their overlapping high-cost G32 phase;
BinaryAdaptive/HybridTrial are omitted because KRS2/KRS3 already pay the hybrid baseline.

For all 11 input files, split exactly as KHC 1 MiB blocks. For each block, encode every candidate
twice in the same fixed order; validate and decode each frame, compare decoded bytes to the
corresponding input block, compare the repeated frame bytes exactly, and keep the smallest reported
length (fixed order resolves ties). Require identical per-candidate frames and selection across
the repeated encodes, and require each portfolio-selected frame to be no larger than the revision-9
`min(MDL,KCS1)` frame.
No additional unit tests are added; the bounded registered E2E probe performs these checks.

The exact candidate archive length is derived without emitting an archive: `484,829 B` is the
registered revision-9 archive length for this exact input. Subtract the sum of revision-9 block
records (`4-byte length prefix + min(MDL,KCS1) frame`) and add the portfolio block-record sum.
Revision 10, if later integrated, is preregistered to retain the same header, manifest, block
prefix, and end-marker lengths, so this delta is exact for that proposed layout. The fixed 7-Zip
26.04 x64 `.7z`/LZMA2 mx9 baseline is `483,599 B` (`-mx=9 -md=64m -mmt=1 -ms=on -mqs=off
-mtm=off -mtc=off -mta=off`; effective method `LZMA2:3m`). The only size pass is
`candidate_archive_bytes * 100 <= 483599 * 95` (maximum candidate `459,419 B`). A pass only permits
separate revision-10 implementation/E2E and performance evaluation; it does not establish format
correctness, product superiority, or performance. Any candidate error, invalid frame, mismatched
roundtrip, nondeterminism, baseline-size invariant failure, timeout, storage failure, or size-gate
miss is a no-go for this fixed condition; do not retry it.

The fixed input is the 11 members under `pipeline-e2e/canterbury/` from
`<作業フォルダー>\TaskArtifacts\UnLhaRe\storage-lifecycle\runs\5e93ed1e99ca4f5ab29d490db421e50b\recovery.zip`
(8,765,120 B, SHA-256 `b74644fac5f89251b15a68db6b2a3bce1bd508c12f0f685a61cd5c96ae1540bb`), with total
2,810,784 B and source manifest SHA-256
`bb63b0d70713c9aefa681347eaf99fb891d59f45923e009ad0deadc9ec9fc438`. The exact revision-9 archive
was `484,829 B`, SHA-256 `648f04505ac91aa1e4e96d82ed26bb85a6ebafcd318bf00273e53ee5fc75cea9`; the 7-Zip archive
was `483,599 B`, SHA-256 `ea8b4b785c245001ab0efb5aa0a21d0339cdf74d8d62d5ccdee75b5f1b8e4299`. This is known
development data, not an independent holdout. No I–P files or additional data are accessed.

Use only the registered `portfolio-size-pilot.ps1` entry with fixed run cap 32 MiB / 96 entries /
300 seconds. Extract only the pinned members inside registered work. Before Cargo, reconfirm the
candidate sources, example, screen source, input, existing CLI/7-Zip, Cargo manifests, and build/
storage helper pins below. Build the Release probe only through `run-serial-cargo.ps1`, with
target-dir and TEMP/TMP under `<作業フォルダー>\UnLhaRe\goal-restore-20261019\`. After the build, record
the generated probe SHA and final runner SHA here and in `RESEARCH_SELECTION_20261005.md`; no
candidate, input, budget, or decision condition may change. Invoke the pilot only through
`run-storage-experiment.ps1` with `KHC_STORAGE_TASK_ID=goal-restore-20261019`. No other build,
input, archive, or timing path is allowed for this pilot. Preserve the runner report and cleanup
evidence under the registered lifecycle; use the Prunlet staged cleanup procedure before starting
any subsequent experiment.

Pinned build command:

```powershell
$env:KHC_STORAGE_TASK_ID = 'goal-restore-20261019'
& .\experiments\khc\run-serial-cargo.ps1 -TransientMiB 256 -CargoArguments @(
    'build','--locked','--offline','--release','--target','x86_64-pc-windows-msvc',
    '--example','khc_portfolio_size_pilot'
)
```

Pre-build pins (2026-10-19; re-hash before Cargo):

| Target | SHA-256 |
| --- | --- |
| `examples/khc_portfolio_size_pilot.rs` | `3f8bf9b6b8aaaca679f70822ec87e4c73d34f14a1542627d2c69b78141922707` |
| all 27 `src/khc/**/*.rs` files, sorted relative-path/length/SHA manifest | `e24f0502e7ecccdd4933fcfc08217bfe11771eb6c229dc46877364a5754ec424` |
| `src/main.rs` | `35ee6bd7a7d222db03f92a1647155c678d752b9a69e793b4749a665fa57c72aa` |
| `Cargo.toml` / `Cargo.lock` | `3b47e50b8e543a5af82617bee4d4bd48ec20fc795a333ba50cbc9e439e0c2fac` / `d8dab69b03805b559440c186ed04c2d0d0ee57eba922306cfa6827bf79985554` |
| existing Release CLI `unlhare-cli.exe` | `50952a6e7781800b946f85a7493bea7ca0923b5a974f34db1ba2baf32d1de6e3` |
| 7-Zip 26.04 x64 `7z.exe` | `95fff19b73eff77c87c0d7bd32822e43fb90dd2932459f962eb532d8dfb6ba53` |
| Canterbury recovery ZIP / 11-file manifest | `b74644fac5f89251b15a68db6b2a3bce1bd508c12f0f685a61cd5c96ae1540bb` / `bb63b0d70713c9aefa681347eaf99fb891d59f45923e009ad0deadc9ec9fc438` |
| `run-serial-cargo.ps1` | `053532f8fa0266b23a6dcc02e60bfb54e94d5d58d874a71692df51dec16a158f` |
| `storage-lifecycle.psm1` / `disk-budget.ps1` | `511ac35885416d0ee7deb6367f2f210d6bda3e71ced3001a590dd90426962ac3` / `506e4c68dc05734bc1a0c02bac6f81d4677e0bcffd9b9fa2b7bd67d53319bdcd` |
| `portfolio-size-pilot.ps1` | `b429ff4e9bff43a3c2021022c36986fc7f21cad95dacffb78ce3de29c80569ad` |
| Release probe `khc_portfolio_size_pilot.exe` | `fb595c1c8ab5b08135fa634c5d6b9e00ea6a2c7d3da8049f4d0aab06f52f6012` |
| `run-storage-experiment.ps1` final SHA-256 | `589f29f9b85e22f900e6a6b11040b88bb2812340d282c347551f9ccfa3059ac3` |

The Release probe was built by the pinned command above with Cargo `--locked --offline`, target
`x86_64-pc-windows-msvc`, one job, and 256 MiB transient reservation. After the compiler correction
(recorded below), Cargo finished but the first wrapper call returned 1 because `VCTIP.exe` survived
the drain grace; it exited naturally. One recovery invocation with unchanged source then completed
with wrapper exit 0 in 0.94 s. The executable is 1,357,312 B at
`<作業フォルダー>\UnLhaRe\goal-restore-20261019\cargo\x86_64-pc-windows-msvc\release\examples\khc_portfolio_size_pilot.exe`.

Pre-registration invocation:

```powershell
$env:KHC_STORAGE_TASK_ID = 'goal-restore-20261019'
Import-Module .\experiments\khc\storage-lifecycle.psm1 -Force
$budget = Assert-KhcStorageBudget -ReserveBytes 72MB
$parameters = @{
    InputRecoveryZip = '<作業フォルダー>\TaskArtifacts\UnLhaRe\storage-lifecycle\runs\5e93ed1e99ca4f5ab29d490db421e50b\recovery.zip'
    InputRecoveryZipSha256 = 'b74644fac5f89251b15a68db6b2a3bce1bd508c12f0f685a61cd5c96ae1540bb'
    ExpectedSourceManifestSha256 = 'bb63b0d70713c9aefa681347eaf99fb891d59f45923e009ad0deadc9ec9fc438'
    KhcExecutable = '<作業フォルダー>\UnLhaRe\goal-restore-20261019\cargo\x86_64-pc-windows-msvc\release\unlhare-cli.exe'
    KhcExecutableSha256 = '50952a6e7781800b946f85a7493bea7ca0923b5a974f34db1ba2baf32d1de6e3'
    ProbeExecutable = '<作業フォルダー>\UnLhaRe\goal-restore-20261019\cargo\x86_64-pc-windows-msvc\release\examples\khc_portfolio_size_pilot.exe'
    ProbeExecutableSha256 = 'fb595c1c8ab5b08135fa634c5d6b9e00ea6a2c7d3da8049f4d0aab06f52f6012'
    SevenZipPath = 'C:\Program Files\7-Zip\7z.exe'
    SevenZipSha256 = '95fff19b73eff77c87c0d7bd32822e43fb90dd2932459f962eb532d8dfb6ba53'
    ExpectedScreenSha256 = 'b429ff4e9bff43a3c2021022c36986fc7f21cad95dacffb78ce3de29c80569ad'
}
& .\experiments\khc\run-storage-experiment.ps1 `
    -ScriptPath .\experiments\khc\portfolio-size-pilot.ps1 `
    -ScriptParameters $parameters -MaxRunMiB 32 -MaxEntries 96 -TimeoutSeconds 300
```

Immediately before registration, re-hash all table entries, verify no pending run/target process and
plain D paths, then run the storage-budget check shown above. The final `STORAGE.md` SHA is recorded
in `RESEARCH_SELECTION_20261005.md`.

The first offline Release probe build stopped at compile time: the gate expression multiplied
`u128` by `u64`. The threshold now converts both operands to `u128`; this is a type-correctness fix
only, with no change to the candidate, inputs, or size gate. No registered pilot ran on the failed
build.

#### Registered pilot result and cleanup (2026-10-19)

The single registered run `b35233c621ef4f7fb8bf7651690cdc20` completed with decision
`go-to-separate-revision-10-integration-and-performance-evaluation`. The report
`portfolio-size-pilot.json` has SHA-256
`cec9a17ddc5ed9929060371fa75bf09f780e4f68fb1cba9daa8a606e3549a128` and is retained in
`<作業フォルダー>\TaskArtifacts\UnLhaRe\goal-restore-20261019\storage-lifecycle\runs\b35233c621ef4f7fb8bf7651690cdc20\recovery.zip`
(1,667,875 B, SHA-256 `dabaf9fd5ab4792a95570cf8dea84a200bbec84576232772b2c231ba3f0c6324`). The paired
recovery manifest SHA-256 is `9044ae1792e221ea4636fa5285635b9612a809a0f20b69639e4de2026bca605a`.

On the fixed development Canterbury11 corpus (11 files, 2,810,784 B, each file happened to be one
block, 1 MiB maximum block size), all four complete-frame candidates were encoded twice and passed
round-trip, deterministic-byte, and revision-9 per-block invariant checks. The hypothetical
candidate archive is 450,309 B versus 484,829 B for revision 9 and 483,599 B for the fixed 7-Zip
26.04 LZMA2 mx9 archive. The preregistered gate `20*C <= 19*A` passes: `20*450,309 = 9,006,180`
and `19*483,599 = 9,188,381`; the candidate is 33,290 B (about 6.88%) smaller than 7-Zip, with
9,110 B headroom under the integer 5%-smaller threshold of 459,419 B. Selected-frame counts were
MDL 8, KCS1 1, KRS2 2, and KRS3 0. Most of the reduction came from `kennedy.xls` (47,654 B versus
80,858 B in revision 9) and `sum` (11,872 B versus 13,188 B).

This permits only a separate revision-10 integration, finite E2E validation, and a later fair
performance evaluation. It is not an actual revision-10 archive, speed/memory measurement,
independent holdout, or general superiority result. No performance or product claim follows from
this size-only pilot.

Cleanup completed through the registered Prunlet CLI protocol in direct CMD calls. Operation
`7bb14822c72e45bea6b39a0d91c0f7fc` passed delete-preview, delete-result, purge-preview, and purge
apply verification; the 20-entry, 3,308,747 B run directory is absent. `complete.json` records
state `complete`, `BeforeBytes=3308747`, and `AfterBytes=0`; the recovery ZIP and manifest remain
available and their hashes were rechecked after purge.

## Revision-10 portfolio integration E2E preregistration (2026-10-19)

The Canterbury11 size-only pilot passed its fixed gate, so the next allowed step is a single
correctness-only integration run for the new revision-10 `PortfolioTrial` strategy (CLI name
`portfolio-trial`). It compares complete candidate frames in fixed tie order: default MDL, KCS1
(`SpatialBitsTrial`), KRS2 (`RecordFastTrial`), then KRS3 (`RecordAdaptiveTrial`). The selected
frame must be the shortest complete frame; strict `<` replacement preserves that order on ties.
The revision-1 default must remain unchanged, and revisions 1 through 9 must remain readable.

Reuse the registered `spatial-mdl-e2e.ps1` / `khc_spatial_mdl_e2e` entry point, extending its
finite matrix without altering the recorded hashes or outcome of the earlier revision-9 run.
Inputs are the already pinned ptt5 recovery member plus deterministic empty, one-byte, byte-range,
text-like, random, block-minus-one, exact-block, and two-block-plus-tail data generated by the E2E.
Before integration, the E2E must check that each of the four candidate frames is deterministic
across two encodes, decodes exactly, and that PortfolioTrial equals the strict minimum selected in
the fixed order. API archive checks must cover revision byte 10, list/verify/extract, complete
byte equality and no-replace behavior. The CLI must create revision 10, list/test/extract it, and
verify complete SHA-256 round trips.

The revision-10 frame allowlist is exactly KHC1 revision-1 default MDL (method 0 or 1), KHC1
revision-2 BinaryAdaptive fallback (method 0, 1, or 3), KCS1, KRS2 fast, and KRS3 adaptive.
The revision-2 fallbacks are emitted by the existing KRS2/KRS3 candidate encoders and must remain
part of the full-frame size comparison used by the pilot. A single API archive patched with a valid
same-input frame for every allowed family and all three allowed revision-2 fallback methods must
verify and extract with exact bytes. Valid KRS1, G32, Delta16, and KHC1 revision-2 method-2 fallback
frames must be rejected. Also reject a corrupted frame, truncation, trailing bytes, and unknown
revision 11 with a recomputed valid archive-header CRC. API verification and CLI test/extract
rejection must leave pre-existing sentinel output unchanged. Preserve the existing
revision-1-through-8 API compatibility sweep and add revision 9 compatibility coverage. The test
is E2E correctness only, not speed, memory, or comparative performance evidence.

Use the fixed fixture and D-drive build outputs from the revision-9 E2E command above. Register
exactly one run with 8 MiB / 96 entries / 300 seconds total, with 240 seconds per child process.
The E2E keeps one 1 MiB-plus-tail source file and covers all candidate boundaries in memory; the
8 MiB run allowance covers its source, both successful API materializations, CLI fixture/output,
and invalid-archive copies without relying on cleanup or another target root.
Before the offline Release build, record the finalized source, example, E2E script, lifecycle
module, Cargo manifest/lockfile, serial-Cargo wrapper, outer runner, and input ZIP hashes below
and in `RESEARCH_SELECTION_20261005.md`; after the build, record both executable SHA-256 values
before starting the run. Build only `unlhare-cli` and `khc_spatial_mdl_e2e` through
`run-serial-cargo.ps1`. Use `run-storage-experiment.ps1` for the one registered E2E run, then
complete its Prunlet cleanup before any further experiment. A failed fixed run is a no-go; do not
retry the same condition. Only a clean pass permits moving on to a separately preregistered
fair-performance evaluation.

### Revision-10 pre-build pins (2026-10-19)

The build-input manifest contains all 37 `src/**/*.rs` files plus `build.rs`, `rust-toolchain.toml`,
`Cargo.toml`, `Cargo.lock`, and `examples/khc_spatial_mdl_e2e.rs` (42 files total). For each file,
form `relative/path<TAB>lowercase-file-SHA256`, sort lines by ordinal path, UTF-8 encode with no BOM
and one final LF, then SHA-256 the resulting bytes. This pins the full Rust source set while the
individual example and tool scripts remain directly inspectable.

| 対象 | SHA-256 |
| --- | --- |
| 42-file Rust/build-input manifest | `33d3ca8895ea039d4b2987548d437c3786fa3ff267e526ef258299999f0160ca` |
| `examples/khc_spatial_mdl_e2e.rs` | `ebc51fd0fedc559480b60fb95ea1d668272e9df23836fb14e5186ea5533aa08a` |
| `src/khc/mod.rs` / `src/main.rs` | `3dca2ae01cc4eccde0df05c39bfee3ae6a53fd884a5fc9c01d83f93598347dec` / `01c21dcd0b3e5a13d997fe2538ffb2f048072f59c40448f32e0249a49effef7c` |
| `KHC_FORMAT.md` / `README.md` | `3565ae18e60587fdc0fa3627aad423a8752af6fd4ece8a0fa1c5d6ef29803fbd` / `05c975fb20e29696d56f082bcbf2309d9b062a07b4b8583cc4cd8e03cda6fdaf` |
| `Cargo.toml` / `Cargo.lock` / `rust-toolchain.toml` | `3b47e50b8e543a5af82617bee4d4bd48ec20fc795a333ba50cbc9e439e0c2fac` / `d8dab69b03805b559440c186ed04c2d0d0ee57eba922306cfa6827bf79985554` / `887f9be066a15585a2c583578e84b0fcb541126d81546276bad3d2ff00d61167` |
| `experiments/khc/spatial-mdl-e2e.ps1` | `1f748812f536ab85f01ce5a20a2fc1143de09dc3c9465d47a3b914803641550d` |
| `experiments/khc/run-serial-cargo.ps1` / `run-storage-experiment.ps1` | `053532f8fa0266b23a6dcc02e60bfb54e94d5d58d874a71692df51dec16a158f` / `1e82897117deac3cea5933741eab7eb59a634db7fb0a3ac93702b6b27182fa44` |
| `experiments/khc/storage-lifecycle.psm1` / `disk-budget.ps1` | `511ac35885416d0ee7deb6367f2f210d6bda3e71ced3001a590dd90426962ac3` / `506e4c68dc05734bc1a0c02bac6f81d4677e0bcffd9b9fa2b7bd67d53319bdcd` |
| pinned ptt5 recovery ZIP / member | `882e7108870c3de5d20de6e87ffc89f390c5d34630930aef73baed9171557f75` / 513,216 B, `0ec3a75089bb52342813496b17e51377bc9eba3cb519a444d67025354841d650` |

Release output paths remain under `<作業フォルダー>\UnLhaRe\goal-restore-20261019\cargo\x86_64-pc-windows-msvc\release\`;
the build uses Rust 1.98.1, `--locked --offline`, one Cargo job, and a 256 MiB transient
reservation. Record `unlhare-cli.exe` and `examples\khc_spatial_mdl_e2e.exe` hashes after build
and before the single 8 MiB / 96-entry / 300-second registration.

### Revision-10 post-build pins (before run registration)

The offline Release build completed for `x86_64-pc-windows-msvc` after one bounded no-rebuild
recovery from the known VCTIP drain condition. These executable hashes were captured before the
registered run and must match the exact `<作業フォルダー>` output paths above.

| 対象 | bytes | SHA-256 |
| --- | ---: | --- |
| Release `unlhare-cli.exe` | 2,558,976 | `4f9fa4e293404c82335ace434271fd646ed62468fb32365d6fcf3e1d0641a403` |
| Release `examples/khc_spatial_mdl_e2e.exe` | 1,640,960 | `f4793249b19b7f93331889e082922c7c9d5f29939e9200b11042f0c1e4474c1a` |

```powershell
$env:KHC_STORAGE_TASK_ID = 'goal-restore-20261019'
Import-Module .\experiments\khc\storage-lifecycle.psm1 -Force
$taskPaths = Get-KhcStorageTaskPaths
$release = Join-Path $taskPaths.CargoTargetRoot 'x86_64-pc-windows-msvc\release'
$parameters = @{
    InputRecoveryZip = '<作業フォルダー>\TaskArtifacts\UnLhaRe\storage-lifecycle\runs\8a849a3267954242bcd8424b93526176\recovery.zip'
    KhcExecutable = Join-Path $release 'unlhare-cli.exe'
    KhcExecutableSha256 = '4f9fa4e293404c82335ace434271fd646ed62468fb32365d6fcf3e1d0641a403'
    E2eExecutable = Join-Path $release 'examples\khc_spatial_mdl_e2e.exe'
    E2eExecutableSha256 = 'f4793249b19b7f93331889e082922c7c9d5f29939e9200b11042f0c1e4474c1a'
    ChildTimeoutSeconds = 240
}
& .\experiments\khc\run-storage-experiment.ps1 `
    -ScriptPath .\experiments\khc\spatial-mdl-e2e.ps1 `
    -ScriptParameters $parameters -MaxRunMiB 8 -MaxEntries 96 -TimeoutSeconds 300
```

## Revision-10 E2E harness-correction follow-up preregistration (2026-10-19)

The first registered run (`b0edb4338a0d4b39bc8c2aaaa83d4464`) did not complete the correctness
matrix. It stopped at `assert_rejected` after `verify_archive` and `extract_archive` both returned
errors for the first corrupt-frame fixture: the pre-existing sentinel was unchanged, while eight
earlier completed entry files remained. This matches the public contract above: extraction is
no-clobber per completed entry, not transactional for the entire archive. The harness incorrectly
required the destination directory to contain only the sentinel and reused that same destination
for every malformed fixture; the CLI loop had the same shared-directory assumption. No codec or
format failure was established, but API/CLI malformed-input completion and legacy checks remain
unverified. The run worktree was removed through the staged Prunlet procedure (5,330,315 bytes);
its recovery ZIP and manifest remain at the pinned lifecycle paths with their original hashes.

This follow-up is a corrected test condition, not a replay of the unchanged run. The Rust E2E now
builds a valid one-entry revision-10 archive containing exactly one 1MiB zero block, patches the
nine preregistered invalid cases into that compact base, and gives each API rejection its own fresh
output directory. The CLI does the same for each invalid archive. Both paths assert the expected
verify/test and extract failures and that a pre-existing sentinel remains byte-identical; they no
longer require archive-wide rollback or share output directories between cases. This retains
full-block-length KRS1, G32, Delta16, and unsupported KHC1-v2 method probes while avoiding nine
copies of outputs from the unrelated multi-entry corpus. No runtime or compression result is
claimed by this correctness E2E.

The fixed capacity remains 8MiB / 96 entries / 300 seconds, with 240 seconds per child. Permit at
most one registered corrected run. A failure is a no-go for this condition; do not repeat it.
Only a complete pass permits a separately preregistered performance evaluation.

### Corrected E2E pre-build pins

The 42-file build-input manifest uses all 37 `src/**/*.rs` files plus `build.rs`,
`rust-toolchain.toml`, `Cargo.toml`, `Cargo.lock`, and `examples/khc_spatial_mdl_e2e.rs`. Each row is
`relative/path<TAB>lowercase-file-SHA256`, ordinal path order, UTF-8 without BOM and a final LF.
The initial corrected-harness pins below were recorded before the first compile attempt. That
attempt failed while compiling the E2E example with E0382 because `default_mdl` was moved into an
earlier fixture list and then reused; no experiment run was registered. The minimal clone fix and
the final build-input pins for the only permitted corrected run are recorded in the amendment
below. The original pins remain as the record of that failed compile attempt.

| 対象 | SHA-256 |
| --- | --- |
| 42-file build-input manifest | `b9f403b69ade1a4ef4861ea047be6b038026e0bd2b9ee80016c7ccce4c4817e6` |
| `examples/khc_spatial_mdl_e2e.rs` / `experiments/khc/spatial-mdl-e2e.ps1` | `9d84e46c1e4c1ef1260cbb04ab04411fd4abeedf8a0149650cbeefc13c734c39` / `23922e92875d9c5af8eef5dd85dbe65f41183782fa65b9bc97dd39260e11da03` |
| `src/khc/mod.rs` / `src/main.rs` | `3dca2ae01cc4eccde0df05c39bfee3ae6a53fd884a5fc9c01d83f93598347dec` / `01c21dcd0b3e5a13d997fe2538ffb2f048072f59c40448f32e0249a49effef7c` |
| `KHC_FORMAT.md` / `README.md` | `3565ae18e60587fdc0fa3627aad423a8752af6fd4ece8a0fa1c5d6ef29803fbd` / `05c975fb20e29696d56f082bcbf2309d9b062a07b4b8583cc4cd8e03cda6fdaf` |
| `Cargo.toml` / `Cargo.lock` / `rust-toolchain.toml` | `3b47e50b8e543a5af82617bee4d4bd48ec20fc795a333ba50cbc9e439e0c2fac` / `d8dab69b03805b559440c186ed04c2d0d0ee57eba922306cfa6827bf79985554` / `887f9be066a15585a2c583578e84b0fcb541126d81546276bad3d2ff00d61167` |
| `run-serial-cargo.ps1` / `run-storage-experiment.ps1` | `053532f8fa0266b23a6dcc02e60bfb54e94d5d58d874a71692df51dec16a158f` / `1e82897117deac3cea5933741eab7eb59a634db7fb0a3ac93702b6b27182fa44` |
| `storage-lifecycle.psm1` / `disk-budget.ps1` | `511ac35885416d0ee7deb6367f2f210d6bda3e71ced3001a590dd90426962ac3` / `506e4c68dc05734bc1a0c02bac6f81d4677e0bcffd9b9fa2b7bd67d53319bdcd` |
| pinned ptt5 recovery ZIP / member | `882e7108870c3de5d20de6e87ffc89f390c5d34630930aef73baed9171557f75` / 513,216 B, `0ec3a75089bb52342813496b17e51377bc9eba3cb519a444d67025354841d650` |

#### Final source pin amendment after the compile diagnostic (before successful Release build)

The only build-input source change after the failed compile was `default_mdl.clone()` in the E2E
fixture list, preserving the frame for the separate malformed-MDL probe. Production codec/API
sources and PowerShell harness are unchanged. The values below supersede the manifest and example
hashes above for the corrected run; all other input, tool, and resource pins remain unchanged.

| 対象 | SHA-256 |
| --- | --- |
| 42-file build-input manifest | `c0ad0f86a684ef5afdbf36b81c2401db5fe2dada4057f5293765e2fdebaf0900` |
| `examples/khc_spatial_mdl_e2e.rs` | `1e4469f44934eebebfb6c879ec087085485c6a01c0466e1adab86277e7e0d2ef` |
| `experiments/khc/spatial-mdl-e2e.ps1` / CLI `src/khc/mod.rs` | `23922e92875d9c5af8eef5dd85dbe65f41183782fa65b9bc97dd39260e11da03` / `3dca2ae01cc4eccde0df05c39bfee3ae6a53fd884a5fc9c01d83f93598347dec` |

After the successful offline Release build, record both rebuilt executable hashes and byte lengths
in this section and in the research selection file before registering the corrected E2E.

#### Corrected follow-up post-build pins (before run registration)

The Release build compiled both targets. The first wrapper call returned exit 1 only because one
`VCTIP.EXE` job process outlived the drain grace; that PID exited naturally, and one bounded
no-rebuild call confirmed Cargo `Finished` and wrapper exit 0. The compile-failure and drain
diagnostic did not register or start an experiment.

| 対象 | bytes | SHA-256 |
| --- | ---: | --- |
| Release `unlhare-cli.exe` | 2,558,976 | `4f9fa4e293404c82335ace434271fd646ed62468fb32365d6fcf3e1d0641a403` |
| Release `examples/khc_spatial_mdl_e2e.exe` | 1,643,008 | `588bc81b9bfb6f39f32f942fe488593457b01e12d266785c8426298a13aa787d` |

Use these exact binaries and the unchanged pinned recovery ZIP for the single corrected run:

```powershell
$env:KHC_STORAGE_TASK_ID = 'goal-restore-20261019'
Import-Module .\experiments\khc\storage-lifecycle.psm1 -Force
$taskPaths = Get-KhcStorageTaskPaths
$release = Join-Path $taskPaths.CargoTargetRoot 'x86_64-pc-windows-msvc\release'
$parameters = @{
    InputRecoveryZip = '<作業フォルダー>\TaskArtifacts\UnLhaRe\storage-lifecycle\runs\8a849a3267954242bcd8424b93526176\recovery.zip'
    KhcExecutable = Join-Path $release 'unlhare-cli.exe'
    KhcExecutableSha256 = '4f9fa4e293404c82335ace434271fd646ed62468fb32365d6fcf3e1d0641a403'
    E2eExecutable = Join-Path $release 'examples\khc_spatial_mdl_e2e.exe'
    E2eExecutableSha256 = '588bc81b9bfb6f39f32f942fe488593457b01e12d266785c8426298a13aa787d'
    ChildTimeoutSeconds = 240
}
& .\experiments\khc\run-storage-experiment.ps1 `
    -ScriptPath .\experiments\khc\spatial-mdl-e2e.ps1 `
    -ScriptParameters $parameters -MaxRunMiB 8 -MaxEntries 96 -TimeoutSeconds 300
```

Before registration, verify the current 42-file manifest, helper-script hashes, both executable
hashes, and the pinned ZIP against the values above and record the final `STORAGE.md` SHA-256 in
`RESEARCH_SELECTION_20261005.md`.

Build the CLI and E2E example only through `run-serial-cargo.ps1` with the same offline Release
command above. Record both new executable byte lengths and hashes, the final pre-run
`STORAGE.md` hash, and the updated `run-storage-experiment.ps1` hash in this file and
`RESEARCH_SELECTION_20261005.md` before registering the one corrected run. The final pre-run
`STORAGE.md` hash is recorded in the research selection file to avoid a self-reference.

## Revision-10 malformed-G32 fixture correction (2026-10-19)

The second registered run (`1d844efed19145eb9e4029b46302202a`) stopped at the API assertion that
expected a `KHCG32B` frame from `Gather32Trial` on a 1MiB zero block. The strategy correctly chose
`KRS1BLK` instead, so the intended foreign-family fixture was never constructed. API invalid cases
0–5 ran; the G32 and later API cases, CLI matrix, and legacy checks did not. This is a fixture
selection error, not a format rejection or codec failure. The worktree was cleaned through staged
Prunlet operation `a126462266f541aab1ed9f2c6b3e3527` (7,196,852 bytes before, 0 after). Recovery ZIP
`<作業フォルダー>\TaskArtifacts\UnLhaRe\goal-restore-20261019\storage-lifecycle\runs\1d844efed19145eb9e4029b46302202a\recovery.zip`
is retained with SHA-256 `bb55201dd11c634aaab16f2cadf7f87e3bdcfd4e1ff2252c49f790bc665bb034`; its
manifest SHA-256 is `54d9d7ce54c736cab039cca83b6ac4eee48dc7411e74a7d855f5d68141012471`. There is no
pending lifecycle run.

One further corrected run is permitted; it is a changed fixture condition, not a replay of the
same failed setup. The Rust E2E now uses the already-created 65,536-byte `g32.bin` skewed input,
creates a separate one-entry base archive from that same source, and patches in `Gather32Trial` on
the identical bytes. The expected length therefore matches and the harness first asserts the
candidate magic is `KHCG32B`. Other malformed-frame cases retain the one-entry base made from the
existing `a-main.bin`; no extra 1MiB source copy is introduced. This isolates revision-10's
unsupported-family rejection without requiring Gather32 to win on unrelated all-zero data.

The cap remains 8MiB / 96 entries / 300 seconds, with 240 seconds per child. At most one run under
this corrected condition may be registered. A failure is a no-go for this condition; do not retry.
No performance result is claimed. The source/build inputs are preregistered below; the final
`STORAGE.md` and rebuilt executable hashes must be added before registration.

| Next corrected run pre-build pin | SHA-256 |
| --- | --- |
| 42-file source/build-input manifest | `f3e87c63e65725b5524f408238dd5cffcaf19ac790ef168fcfea8faceb0240d7` |
| `examples/khc_spatial_mdl_e2e.rs` | `aa0a0a097cb85d174595b4489ace098daa4be0a313cb4feb3d32b8893f2c3a15` |
| unchanged `experiments/khc/spatial-mdl-e2e.ps1` | `23922e92875d9c5af8eef5dd85dbe65f41183782fa65b9bc97dd39260e11da03` |
| unchanged `src/khc/mod.rs` / `src/main.rs` | `3dca2ae01cc4eccde0df05c39bfee3ae6a53fd884a5fc9c01d83f93598347dec` / `01c21dcd0b3e5a13d997fe2538ffb2f048072f59c40448f32e0249a49effef7c` |
| pinned ptt5 recovery ZIP | `882e7108870c3de5d20de6e87ffc89f390c5d34630930aef73baed9171557f75` |

The earlier preregistrations and their build/run hashes above remain as immutable records of their
respective conditions. This amendment supersedes only the next-run source pin and fixture design.

### Final corrected-run build pins (before registration)

The registered build command was run through `run-serial-cargo.ps1` with one job, 256MiB transient
reservation, offline/locked Release mode, target `x86_64-pc-windows-msvc`, and only the CLI plus
this E2E example. Cargo finished successfully with exit 0 in 14.39 seconds; the wrapper observed
450,180,292 peak bytes against the fixed 6,175,228,536-byte cap and performed no deletion. The
linker emitted one informational library/object creation warning; there were no Rust diagnostics.
The helper-script and source pins matched the preregistration, and no Cargo/Rust/E2E processes
remained after the build.

| Final pre-run target | bytes | SHA-256 |
| --- | ---: | --- |
| Release `unlhare-cli.exe` | 2,558,976 | `4f9fa4e293404c82335ace434271fd646ed62468fb32365d6fcf3e1d0641a403` |
| Release `khc_spatial_mdl_e2e.exe` | 1,645,568 | `c0d3866586c504f830fddf8c931623f1d964fc25baa226e75bce2afc99f97c2c` |
| `experiments/khc/run-storage-experiment.ps1` | 31,417 | `1e82897117deac3cea5933741eab7eb59a634db7fb0a3ac93702b6b27182fa44` |

The final pre-run `STORAGE.md` hash is pinned in `RESEARCH_SELECTION_20261005.md` to avoid a
self-reference. Recheck the manifest, these exact binaries, helper scripts, input ZIP, and no-pending-run
state immediately before registering the sole corrected E2E.

## Revision-10 fixed-tree-cap E2E correction (2026-10-19)

The registered run `f26e7d189380473d881d1bf602aa3bd1` used the pins above and the fixed 8MiB / 96
entry / 300-second registration. The run monitor stopped the child when its recursive work tree
reached 97 items, one above the 96-entry cap; the original error was `Owned tree exceeds
entry/path metadata bound`. The work tree was 7,245,793 bytes at that point, below its byte limit.
The API matrix (all nine invalid archives, including G32) and revisions 1–9 compatibility outputs
were present, and the CLI had reached its malformed-archive output setup, but the final JSON report
was absent. Therefore the combined API/CLI E2E did not complete and is not a pass or performance
result.

After the registered child stopped, a bounded diagnostic ran `khc-test` and `khc-extract` against
the saved truncated `bad-2.khc`: both returned exit 1, the existing sentinel remained `keep`, and
the completed `payload.bin` was byte-identical to `api/source/a-main.bin` (1,048,833 bytes,
SHA-256 `5a257432083de2353c16bc0937134e4dc56ce2fb1e959fff1f85e4c68081c3d6`). This diagnostic is
not part of the E2E result. The recovered work then measured 8,294,626 bytes and 98 filesystem
items; its recovery manifest contains 99 entries including the root. It was recovered through
`Recover-KhcAbandonedStorageRun` after adding the registered `spatial-mdl-e2e.ps1` entry point to
the helper's recovery allowlist. Staged Prunlet operation `226b9eb30c9b4d88950829944b0c543d`
deleted and purged 99 validated items; finalizer recorded 8,294,626 bytes before and 0 after. The
recovery ZIP (646,812 bytes, SHA-256
`8c23ec35f80e61aafc0de53860020e6a8c5bc1c4efa0612f1d5015ae429ba4b3`) and manifest (SHA-256
`6e5bf1a96a6c753d5d642f0767e64b13688001bdc5aaaf78ad6dcd316d07abd9`) are retained. There is no
pending run.

The next condition reduces only temporary entry count while preserving the 8MiB / 96 / 300-second
limits and all nine malformed cases. Observed API extraction showed that bad-2 (truncated trailer)
and bad-3 (trailing byte) can leave the already-completed `payload.bin` even though the archive is
rejected. The Rust harness now shares one sentinel output directory among the seven invalid-frame
cases that must not produce a file, and gives each trailer case its own directory, checking that
any retained payload exactly matches the source. The CLI harness uses the same three groups and
byte-checks payloads. From the measured 97-item partial tree, completing the old layout would have
required about 110 items (six remaining directory/sentinel pairs plus the report); grouping both
API and CLI rejection outputs reduces the projected full tree to about 86 items, within 96. This is
a projection from observed files, not an executed result.

| Next fixed-tree-cap run pre-build pin | SHA-256 |
| --- | --- |
| 42-file source/build-input manifest | `8a23554ebea6590f3198db430913944827d0f8ca27e6155e513b3b60e89426c7` |
| `examples/khc_spatial_mdl_e2e.rs` | `560905920af192ac77be18fcb908f87a97aea6d8dd7bc4adee99b07a666a2b31` |
| `experiments/khc/spatial-mdl-e2e.ps1` | `b2374919aa504335ca9eb08cab5fd27f138b90f2a1791285a4c392153ef34bbc` |
| recovery helper `experiments/khc/storage-lifecycle.psm1` | `cdc969afd996a75882be0111301c336a85f1e3519c9952fdda800dc44f2a9be3` |
| `run-storage-experiment.ps1` / `run-serial-cargo.ps1` | `1e82897117deac3cea5933741eab7eb59a634db7fb0a3ac93702b6b27182fa44` / `053532f8fa0266b23a6dcc02e60bfb54e94d5d58d874a71692df51dec16a158f` |
| pinned ptt5 recovery ZIP | `882e7108870c3de5d20de6e87ffc89f390c5d34630930aef73baed9171557f75` |

One corrected run is allowed for this reduced-tree condition. The CLI/E2E binaries must be rebuilt
with the pinned source inputs through the serial Cargo wrapper, then their hashes and the final
pre-run `STORAGE.md` hash must be added here and to the research selection file before registration.

### Reduced-tree final pre-run build pins

The offline, locked Release build used one job, a 256MiB transient reservation, target
`x86_64-pc-windows-msvc`, and only the CLI plus this E2E example. Cargo compiled successfully in
13.09 seconds. The first wrapper call returned 1 because `VCTIP.EXE` remained in its job past the
drain grace; PID 31612 exited naturally, and one bounded no-rebuild wrapper call returned 0 with
Cargo `Finished`. The first call's sampled peak was 450,189,634 bytes, with no deletion. The linker
reported only its informational library/object creation warning.

| Final reduced-tree pre-run artifact | bytes | SHA-256 |
| --- | ---: | --- |
| 42-file source/build-input manifest | — | `8a23554ebea6590f3198db430913944827d0f8ca27e6155e513b3b60e89426c7` |
| Release `unlhare-cli.exe` | 2,558,976 | `4f9fa4e293404c82335ace434271fd646ed62468fb32365d6fcf3e1d0641a403` |
| Release `khc_spatial_mdl_e2e.exe` | 1,648,640 | `d4bb3554a070d8abaffe0338683bf28bfacb13d47ffc4d2b3d6e095631f28d01` |
| `examples/khc_spatial_mdl_e2e.rs` | 22,743 | `560905920af192ac77be18fcb908f87a97aea6d8dd7bc4adee99b07a666a2b31` |
| `experiments/khc/spatial-mdl-e2e.ps1` | 11,599 | `b2374919aa504335ca9eb08cab5fd27f138b90f2a1791285a4c392153ef34bbc` |
| recovery helper `experiments/khc/storage-lifecycle.psm1` | 73,377 | `cdc969afd996a75882be0111301c336a85f1e3519c9952fdda800dc44f2a9be3` |
| `experiments/khc/run-storage-experiment.ps1` | 31,417 | `1e82897117deac3cea5933741eab7eb59a634db7fb0a3ac93702b6b27182fa44` |
| pinned ptt5 recovery ZIP | 769,634 | `882e7108870c3de5d20de6e87ffc89f390c5d34630930aef73baed9171557f75` |

The pre-registration storage check found 1,790,238,086 B total against 32,212,254,720 B, 1,597,696,133 B
Cargo against 6,442,450,944 B, 637,566,026 B external against 2,147,483,648 B, 171,782,157 B
lifecycle against 1,073,741,824 B, 547,556,679,680 B free on D:, and no pending lifecycle
reservation or target process. Rust formatting and both helper PowerShell AST parses passed; the
CLI reports `unlhare 1.0.4`. The final pre-run `STORAGE.md` hash is recorded in the research
selection file to avoid self-reference.

### 2026-10-19 fixed-cap failure and recovery amendment

The one reduced-tree correctness run registered as `6099198442bf4f70a2002977dfa3c1e8` did not
complete and produced no `spatial-mdl-e2e.json`; it is not an E2E pass or a performance result.
The registered limit remained 8,388,608 bytes / 96 entries / 300 seconds. The monitor observed
9,343,435 bytes and 87 entries, exceeding only the byte limit by 954,827 bytes (0.91 MiB). Four
truncated/trailing extraction outputs each contained 1,048,833 bytes; all other outputs remained
within the entry limit.

The standard abandoned-run recovery previously refused any byte overrun, which left a monitored
run unrecoverable after writes landed between 100 ms samples. Recovery now allows at most 1 MiB
above the original registered cap for preservation and cleanup only; it does not change
`run.json`, the experiment cap, or permit another run. The recovery manifest records the original
cap, measured bytes, overrun, and recovery-only allowance. This run's 954,827-byte overrun was
within that allowance, all 87 child entries were SHA-256 verified into its retained recovery ZIP,
and the exact work directory was removed through the registered Prunlet sequence. Finalizer
recorded 9,343,435 bytes before and 0 after. Prunlet operation `bc04bc3f29cf40e8ba0d9e4a2c09dc49`
validated and purged 88 items including the work root. The recovery ZIP is 656,431 bytes with
SHA-256 `3d276bed2a4c08241489851c38bc1a43ac85f442dfdea865c7ba9eb935be21ae`; its manifest SHA-256
is `def8a922278485e4df237dc411f0e9c7c656d531da62d0b64654dc81756d5730`.

The next correctness run is a changed fixture condition, not a same-condition retry: the archive
used only for truncated/trailing corruption cases now has a 65,536-byte `g32.bin` payload instead
of the 1 MiB `a-main.bin`. API and CLI still check rejection and any retained partial payload
against the exact source bytes; all nine invalid archives and the normal archive, round-trip, and
revision-1–9 cases remain. This reduces the four observed partial-payload outputs by 3,933,188
bytes in aggregate while retaining the fixed 8 MiB / 96 / 300-second cap. It is intended to keep
the complete correctness E2E below the same run cap, not to change any performance criterion.

Current changed-source hashes before the next build:

| Source | SHA-256 |
| --- | --- |
| `examples/khc_spatial_mdl_e2e.rs` | `1b7183d12676b5c573a85c2d49e0c99e8a3ac1bc0f7b859f4e03d4d9901554e5` |
| `experiments/khc/spatial-mdl-e2e.ps1` | `099153c0493f6e8d1736f52cebdbf044c50baf64f0310c55f0bcdb0ab0177b8b` |
| `experiments/khc/storage-lifecycle.psm1` | `b6b6adaff2d887a43e7f8a3a3412029d130873e7b8e687988fb76c9508c95caf` |

#### Modified-fixture Release build and next-run pre-registration (2026-10-19)

The modified 42-file Rust/build-input manifest is SHA-256
`82373547f52adf611a6d1bb56b805b7082577887ecdd02372bc04a0a8950047e`. `rustfmt --edition 2024
--check examples/khc_spatial_mdl_e2e.rs` and PowerShell AST parsing of the E2E and lifecycle
scripts passed. The locked offline Release build used one Cargo job, target
`x86_64-pc-windows-msvc`, and a 256-MiB transient reservation through `run-serial-cargo.ps1`;
Cargo finished in 13.59 seconds (wrapper 14.29 seconds), with 445,024,073 B start/end and
450,189,650 B sampled peak against its fixed 6,175,228,536-B cap. It made no deletions.

| Modified-fixture pre-run artifact | bytes | SHA-256 |
| --- | ---: | --- |
| Release `unlhare-cli.exe` | 2,558,976 | `4f9fa4e293404c82335ace434271fd646ed62468fb32365d6fcf3e1d0641a403` |
| Release `khc_spatial_mdl_e2e.exe` | 1,648,640 | `f2776733fa522278c9c5123d07f782ccb2cb9e698a56b876b5a7ea220c76d20d` |
| 42-file Rust/build-input manifest | — | `82373547f52adf611a6d1bb56b805b7082577887ecdd02372bc04a0a8950047e` |
| `examples/khc_spatial_mdl_e2e.rs` | 22,744 | `1b7183d12676b5c573a85c2d49e0c99e8a3ac1bc0f7b859f4e03d4d9901554e5` |
| `experiments/khc/spatial-mdl-e2e.ps1` | 11,596 | `099153c0493f6e8d1736f52cebdbf044c50baf64f0310c55f0bcdb0ab0177b8b` |
| `experiments/khc/storage-lifecycle.psm1` | 73,844 | `b6b6adaff2d887a43e7f8a3a3412029d130873e7b8e687988fb76c9508c95caf` |
| `experiments/khc/run-storage-experiment.ps1` | 31,417 | `1e82897117deac3cea5933741eab7eb59a634db7fb0a3ac93702b6b27182fa44` |
| pinned ptt5 recovery ZIP | 769,634 | `882e7108870c3de5d20de6e87ffc89f390c5d34630930aef73baed9171557f75` |

The CLI reports `unlhare 1.0.4`. Pre-registration budget is 1,791,048,127 B total / 32,212,254,720 B,
1,597,696,133 B Cargo / 6,442,450,944 B, 638,376,067 B external / 2,147,483,648 B,
172,592,198 B lifecycle / 1,073,741,824 B, and 546,866,130,944 B free on D:. There is no pending
lifecycle reservation. No Cargo, rustc, CLI, or E2E process is running. One detached `VCTIP.EXE`
(PID 9584; Visual Studio toolchain path) remained; it used 0 ms CPU over a 2-second sample and
60,448,768 B working set. This correctness-only E2E has no performance timing or memory claim;
performance runs still require their stricter quiet-process gate.

The next registration remains exactly 8 MiB / 96 entries / 300 seconds, with
`ChildTimeoutSeconds=240`, the fixed ptt5 recovery ZIP above, and the two binary hashes in this
table. The final pre-run `STORAGE.md` SHA-256 is pinned in `RESEARCH_SELECTION_20261005.md` before
registration. The output cap, malformed-case count, and performance criteria are unchanged except
for the explicitly documented 65,536-byte corruption-fixture payload.

#### 65,536-byte fixture attempt `adba876cae654be1a35642faf3a58425` (2026-10-19)

The run used the exact 8 MiB / 96-entry / 300-second registration, 240-second child timeout,
the pinned ptt5 recovery ZIP, and the binaries listed above. It stopped in the API E2E before the
CLI matrix: `khc_spatial_mdl_e2e.rs:482` expected two frames in `invalid-base.khc`, but the new
65,536-byte `g32.bin` correctly produced one frame (`left: 1`, `right: 2`). It measured
4,059,113 B and 33 entries, both within the cap; there is no final E2E report, so this is not a
pass or performance result.

The 34 Prunlet-validated items (work root included) were preserved and removed through the
registered lifecycle. Operation `be6555d6629e4599aa7cd71787a4ba63` finalized 4,059,113 bytes before
and 0 after. The retained recovery ZIP is 391,406 bytes, SHA-256
`2939bb1ea5c809e20a0584f7b186d59aaf5242e66b5efb06042306ceaabca3d0`; recovery manifest SHA-256
is `c669099acd4fff5cd123a5da7dfcb321ede6985a0e1bf044f0c2da244463a704`.

The only source correction for the next attempt is the frame-count assertion: the invalid base
now expects one frame. No product-format code or acceptance criteria changed. This is a
failure-driven correction required to execute the full API/CLI matrix, not an unchanged retry.
Before another registration, rebuild and pin the changed E2E binary, Rust/build-input manifest,
and final `STORAGE.md` hash in the research selection.

#### Frame-count assertion correction build and next-run pins (2026-10-19)

After the one-line assertion fix, the updated 42-file Rust/build-input manifest is SHA-256
`85a8e995cbabb3ccf941b1995087c71374cc5bceadd42299237fd3fab4441c02`. `rustfmt --edition 2024
--check examples/khc_spatial_mdl_e2e.rs` and PowerShell AST parsing passed. The locked offline
Release build used one Cargo job, target `x86_64-pc-windows-msvc`, and a 256-MiB transient
reservation through `run-serial-cargo.ps1`; Cargo finished in 15.19 seconds (wrapper 16.00
seconds), with 445,024,073 B start, 449,922,038 B sampled peak, and 445,023,561 B end against its
fixed 6,175,228,536-B cap. It made no deletions.

| Corrected-fixture pre-run artifact | bytes | SHA-256 |
| --- | ---: | --- |
| Release `unlhare-cli.exe` | 2,558,976 | `4f9fa4e293404c82335ace434271fd646ed62468fb32365d6fcf3e1d0641a403` |
| Release `khc_spatial_mdl_e2e.exe` | 1,648,128 | `5dc4331196cac4ecf79bfac005792f4f3d8cf8a8781e9d85e3bde7c2cdacf4d0` |
| 42-file Rust/build-input manifest | — | `85a8e995cbabb3ccf941b1995087c71374cc5bceadd42299237fd3fab4441c02` |
| `examples/khc_spatial_mdl_e2e.rs` | 22,744 | `9d834c3c255fe2e14b920c47fca309bb1cb8d4e517b19ffc4221ede6faffd07c` |
| `experiments/khc/spatial-mdl-e2e.ps1` | 11,596 | `099153c0493f6e8d1736f52cebdbf044c50baf64f0310c55f0bcdb0ab0177b8b` |
| `experiments/khc/storage-lifecycle.psm1` | 73,844 | `b6b6adaff2d887a43e7f8a3a3412029d130873e7b8e687988fb76c9508c95caf` |
| `experiments/khc/run-storage-experiment.ps1` | 31,417 | `1e82897117deac3cea5933741eab7eb59a634db7fb0a3ac93702b6b27182fa44` |
| pinned ptt5 recovery ZIP | 769,634 | `882e7108870c3de5d20de6e87ffc89f390c5d34630930aef73baed9171557f75` |

The CLI reports `unlhare 1.0.4`. Pre-registration budget is 1,791,502,215 B total / 32,212,254,720 B,
1,597,695,621 B Cargo / 6,442,450,944 B, 638,830,155 B external / 2,147,483,648 B,
173,046,798 B lifecycle / 1,073,741,824 B, and 546,591,977,472 B free on D:. There is no pending
lifecycle reservation. No Cargo, rustc, CLI, or E2E process is running. Detached Visual Studio
`VCTIP.EXE` PID 9584 remained at 0 ms CPU over a fresh 2-second sample (59,858,944 B working set);
this correctness-only run makes no performance or memory claim.

The next registration is failure-driven and uses the same 65,536-byte `g32.bin` corruption
fixture, now with the corrected one-frame assertion. Run only the preregistered script, pinned
recovery ZIP and binaries above with `ChildTimeoutSeconds=240`, outer cap 8 MiB / 96 entries /
300 seconds. The final pre-run `STORAGE.md` SHA-256 is pinned in the research selection before
registration. No product format code, candidate protocol, or acceptance criterion changed.

#### Completed revision-10 correctness E2E `2358ef6daec7423d968be896e2452803` (2026-10-19)

The failure-driven one-frame assertion correction allowed the full registered E2E to finish under
8 MiB / 96 entries / 300 seconds. The report is `spatial-mdl-e2e.json` in the retained recovery ZIP
(7,162 bytes, SHA-256 `6461140f9c4419e417e95d677647b11a5382056b3c45d7a0fac75b92822299bf`). It is explicitly
a finite correctness E2E, not a performance benchmark. The API example exited 0 and reported
revision 10, eight frames, the five expected frame families, nine malformed archives rejected,
legacy revisions 1–9, and the memory-reservation guard check; the API archive was 43,218 bytes.
The CLI report contains 34 checked commands: 14 expected successes and 20 expected failures
(no-replace and nine malformed cases through both `test` and `extract`). It also created, tested,
and extracted a two-file archive, byte/hash-verified both outputs, and read revisions 1–9. The CLI
archive SHA-256 is `cdfbd2370ce837af88427b332714e698bd1341b6c095c68142ef5f8cc155447a`; restored
`ptt5.bin` and `short.bin` hashes match their inputs.

The run measured 5,453,097 B against 8,388,608 B and 89 inventory entries (including the work root,
74 files) against the 96-entry registration. Registered Prunlet cleanup validated and purged 89
items using operation `3105717da6f74ce6ae2097a4cd9afeb9`; finalizer recorded 5,453,097 B before and
0 after. The retained recovery ZIP is 746,810 bytes, SHA-256
`be65ba1ec8a6c312b167f4fc8f247f582a31dddb29a1e33af56f4c2bc8be3eae`; its recovery manifest SHA-256
is `00176acc0e126c5b5ba5cf1346fb8c2cfe13687194d4608ec8a3926d00d1cc47`. The run is complete,
there is no pending lifecycle reservation, and the work directory is absent. No compression-ratio,
speed, or memory comparison against 7-Zip follows from this E2E.

#### Revision-10 Canterbury11 product screen pre-registration (2026-10-19)

This is a development-only, one-time comparison of the integrated KHC revision-10
`PortfolioTrial` CLI product against current-stable 7-Zip. It does not evaluate a holdout, establish
general superiority, or complete the GOAL. The official 7-Zip download page identifies 26.04 as
the current Windows release (2026-10-05; checked 2026-10-19):
<https://www.7-zip.org/download.html>.

| Fixed input/tool | Bytes | SHA-256 |
| --- | ---: | --- |
| Canterbury11 raw input (11 files) | 2,810,784 | `bb63b0d70713c9aefa681347eaf99fb891d59f45923e009ad0deadc9ec9fc438` manifest |
| Recovery ZIP `runs/5e93ed1e99ca4f5ab29d490db421e50b/recovery.zip` | 8,765,120 | `b74644fac5f89251b15a68db6b2a3bce1bd508c12f0f685a61cd5c96ae1540bb` |
| Release `unlhare-cli.exe` (`unlhare 1.0.4`) | 2,558,976 | `4f9fa4e293404c82335ace434271fd646ed62468fb32365d6fcf3e1d0641a403` |
| 7-Zip 26.04 `C:\Program Files\7-Zip\7z.exe` | 577,536 | `95fff19b73eff77c87c0d7bd32822e43fb90dd2932459f962eb532d8dfb6ba53` |
| 37-file `src/**/*.rs` manifest (ordinal path, byte length, file SHA-256) | — | `034b15490a5c4a59ec1dcc3eb7c331df5be550ce0ab04fc99d7b52e30eaf06ac` |
| 42-file Rust/build-input manifest for the pinned Release CLI | — | `85a8e995cbabb3ccf941b1995087c71374cc5bceadd42299237fd3fab4441c02` |
| `Cargo.toml` / `Cargo.lock` | — | `3b47e50b8e543a5af82617bee4d4bd48ec20fc795a333ba50cbc9e439e0c2fac` / `d8dab69b03805b559440c186ed04c2d0d0ee57eba922306cfa6827bf79985554` |
| `portfolio-7zip-product-screen.ps1` | 27,429 | `7dcab75d9811dc1b5af8bb23d4594995de3a2e3ed290a679643a9eb8a01203b7` |
| `run-storage-experiment.ps1` | 35,588 | `1b32ac958d00efbc66a31dd76d01ad597a3eae0b1a02dfc931d2f21090daaa24` |
| `storage-lifecycle.psm1` / `disk-budget.ps1` | 74,194 / 2,004 | `9686b6b258b4fc7b64e538dda7d32a0c3a355dbfa3ce12daa801395e51f942a0` / `506e4c68dc05734bc1a0c02bac6f81d4677e0bcffd9b9fa2b7bd67d53319bdcd` |

The exact development input is the complete pinned Canterbury11 set; each archive must contain
the eleven names in ordinal order and each extraction must reproduce all names, lengths and SHA-256
values. The KHC archive must be revision 10 with 1 MiB blocks and only known PortfolioTrial frame
families. 7-Zip uses `-t7z -mx=9 -m0=lzma2:d=64m -mmt=1 -ms=on -mqs=off`, timestamps disabled,
UTF-8 console/list encoding, and the same sorted explicit file list. Every archive's `-slt` listing
must report one solid block, eleven member records, a uniform effective LZMA2 dictionary no larger
than 64 MiB, exact names/order and no stored file timestamps. The actual format checks, not argv
alone, determine whether the configured comparison is valid.

Run one warmup and nine measured paired rounds, alternating which product runs first. Each sample
times full archive creation and full filesystem extraction; setup, input hashing and archive-format
inspection are outside the timed interval. Before each timed command require five consecutive
one-second `_Total` CPU readings at or below 15%; a failed gate is a stop with no retry. Each child
command has a 60-second limit and a 160 MiB per-process cap checked against peak working set, peak
paged memory and sampled private bytes (10 ms polling); the registered outer worker limit is 1,800
seconds. Archive SHA/length must be deterministic across all ten runs per product. All 20 extracted
trees must match the pinned manifest. The development screen passes only if the candidate archive
is at most 95% of the 7-Zip archive **and** both candidate creation and extraction wall-time
medians are no greater than their 7-Zip medians. These are the rate-priority conditions in
`GOAL_GATE_20261005.md`; this one development corpus is only a screen, not the required separate
order reproduction or held-out validation.

The fixed registration is 128 MiB / 512 entries / 1,800 seconds and is available only to this
pinned runner. All other `run-storage-experiment.ps1` callers remain capped at 32 MiB; the lifecycle
module requires an explicit screen-specific flag and exact 128 MiB / 512-entry pair. Storage
estimate: up to 20 archives at `U + 65,536` B each, 20 complete extraction trees, one 2,810,784-B
source tree and a 512 KiB report reserve total 117,077,152 B, leaving 17,140,576 B below the
128 MiB ceiling. The predicted tree is below 512 entries. Input ZIP is read from its existing
retained path and is not copied into the run. All output and child `TEMP`/`TMP` stay under the
registered work directory. The entrypoint checks every fixed path/hash, source manifest, tool
version, capacity and lifecycle precondition before registration; the worker repeats the relevant
pins. Any preregistration or execution failure is recorded as a stop/no-go, not retried unchanged.

Register only through this exact command after the final pre-run budget and process checks:

```powershell
$env:KHC_STORAGE_TASK_ID = 'goal-restore-20261019'
$screenParameters = @{
    InputRecoveryZip = '<作業フォルダー>\TaskArtifacts\UnLhaRe\storage-lifecycle\runs\5e93ed1e99ca4f5ab29d490db421e50b\recovery.zip'
    KhcExecutable = '<作業フォルダー>\UnLhaRe\goal-restore-20261019\cargo\x86_64-pc-windows-msvc\release\unlhare-cli.exe'
    SevenZipPath = 'C:\Program Files\7-Zip\7z.exe'
}
& .\experiments\khc\run-storage-experiment.ps1 `
    -ScriptPath .\experiments\khc\portfolio-7zip-product-screen.ps1 `
    -ScriptParameters $screenParameters -MaxRunMiB 128 -MaxEntries 512 -TimeoutSeconds 1800
```

### Aozora development-only 7-Zip screen integration snapshot before preregistration (2026-10-20)

This is the initial integration snapshot, recorded before the immutable `campaign-start.json` was
created. At that checkpoint there were no Aozora registrations, builds, timed commands, cleanup
operations, or performance results. The current preregistration is recorded at the end of this
document. The prior e-Gov campaign remains stopped before registration and must not be retried. This
is a distinct development-only input condition, not an independent holdout or evidence of 7-Zip
superiority.

The fixed input package is
`<作業フォルダー>\TaskArtifacts\UnLhaRe\goal-restore-20261019\aozora-dev-20261020\input.zip` (222,247 B,
SHA-256 `9772d6af224028a70c2d50af8f64faebf03de9a487a08fee566de4c1128cb0b6`). Its only members are
`input/bocchan.txt` (209,990 B, SHA-256
`8b1087162da44dbf54705c15f5ba62c7c07db86bb6f38caacd4f5beb62e4618b`) and `input/lemon.txt`
(12,019 B, SHA-256 `979e3e94b2537ef922851023bef4c32530ba4b7eef2e3c15bf66c80a495a5512`). The package
manifest is `e7ba78c324e97d677f1e1c9aa0371234666a643227fccfbab4c2d70db1204307`; the original
candidate manifest is `caa078a5053669dfd0fb90ebe9d3941b69a76a36600dec2579495f0de58c516d`; and the
basename-sorted `path<TAB>bytes<TAB>SHA-256` file-set digest (UTF-8, no BOM, LF, no final LF) is
`4d9ded91fe0a2e7657cce870f7fd39a4c83c8b7fe5e26f7230ebd8e53c1d2ea6`. Both ZIP members and all
digests were checked against the frozen profile. The selection document records provenance and
rights caveats; these two works are one Aozora source family and remain development/tuning-only.

The registered profile identifier is `AozoraDevelopment20261020`. A future immutable marker must
bind task `goal-restore-20261019`, the input/member manifests, source/tool/script pins below, and a
new explicit-UTC 30-minute window. It must be created and preregistered before any run. The fixed
design is 20 serial one-sample registrations: rounds 0–9, one `portfolio-trial` revision-10 sample
and one 7-Zip 26.04 sample per round, alternating the first strategy by parity; round 0 is warmup
and rounds 1–9 are measured. Each run is capped at 32 MiB / 512 entries / 300 seconds; each child
at 160 MiB / 60 seconds; the campaign at 1,800 seconds. A fresh five-sample external `_Total` CPU
gate at or below 15% is required before the first registration and each timed command. No failed
gate, sample, cleanup, or deadline is retried. Complete the full Prunlet lifecycle for each run
before registering the next, and aggregate only after the fixed deadline. The exact 7-Zip command
request remains solid LZMA2 level 9, `-m0=lzma2:d=64m`, create `-mmt=1`, extract `-mmt=4`, with
the existing timestamp/attribute and solid-mode options. The worker and Aozora aggregator now agree
on one effective dictionary value in `0 < bytes <= 64 MiB`; the e-Gov aggregator retains its prior
exact-64-MiB check. The observed effective value remains unknown until a valid sample executes.

Current integration pins (all four PowerShell files parsed without errors and have no trailing
whitespace; independent review confirmed the task-binding and dictionary-acceptance fixes):

| Artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| `portfolio-7zip-product-screen.ps1` | 35,069 | `4a0042a84eeca12e5f7590f1b8f06b5cbfb3eee67128c4126a7a9d292b93e8b5` |
| `run-storage-experiment.ps1` | 40,667 | `4653d3f765da0c8ced72177c0f190d3bc2771a9e132b3aee176145b08f79ecfe` |
| `storage-lifecycle.psm1` | 94,868 | `18aa24991b267c7004f6da7cd163fb9e60f76c5ac6a273d276d94cd914f7f114` |
| `aggregate-portfolio-7zip-product-screen.ps1` | 42,853 | `c67c91be75c412e7f96a58d6caeb0691a277e0e5335711a5fa7a8fdca26471c7` |
| `disk-budget.ps1` | — | `506e4c68dc05734bc1a0c02bac6f81d4677e0bcffd9b9fa2b7bd67d53319bdcd` |
| `Cargo.toml` / `Cargo.lock` | 1,414 / 30,555 | `3b47e50b8e543a5af82617bee4d4bd48ec20fc795a333ba50cbc9e439e0c2fac` / `d8dab69b03805b559440c186ed04c2d0d0ee57eba922306cfa6827bf79985554` |
| Rust source manifest / KHC manifest | 37 files / 27 files | `0f549ab7f8c675b8ef241279d8ab29f90e9c7b7e32a5bc08c7effd0dc861c404` / `15a4ec2660cd8eecf83743ce347173c971c822c0ce95e0155672c5ed19635500` |
| Release CLI `unlhare-cli.exe` | 2,575,360 | `3dd0e0503ed6ec11c90ad1ff9ee69b2e34c564f8710871ab182dd684f27b7b4b` |
| 7-Zip 26.04 `7z.exe` | — | `95fff19b73eff77c87c0d7bd32822e43fb90dd2932459f962eb532d8dfb6ba53` |

The target Rust build completed through `run-serial-cargo.ps1` for x64 MSVC; the wrapper first
returned nonzero while `VCTIP.EXE` remained in its job, then the helper exited and a no-op wrapper
invocation succeeded. No independent build receipt was found. This build was for the already
existing schedule-replay candidate; it does not constitute Aozora benchmark evidence. A future run
still requires a fresh budget/process/path/source/input/tool preflight and CPU gate, and the start
marker must use the pins above. Acceptance remains the preregistered deterministic output, format
validation, exact restoration, size at most 95% of 7-Zip, and no-slower revision-10 create/extract
medians; this development screen alone cannot establish independent-holdout performance.

### e-Gov XML/CSV revision-10 / 7-Zip fixed product screen

This is a separate development screen on the fixed 100-file e-Gov law XML/CSV corpus, not a retry
of the Canterbury11 CPU-gate stop. The exact campaign is `a42eb7bfbedf4fa780c4d210385b24c6`, fixed
to `2026-10-19T19:00:00Z` through `2026-10-19T19:30:00Z` (2026-10-20 04:00–04:30 JST). Its immutable
`campaign-start.json` is at
`<作業フォルダー>\TaskArtifacts\UnLhaRe\goal-restore-20261019\egov-screen-20261020\campaign-start.json`
(SHA-256 `1ec16512fc8b342407c391c80693598e506136f7b76dfff5e67d24df96e95afe`). No registration is
permitted before the fixed start and a fresh five-reading external `_Total` CPU gate at or below
15%, sampled after one-second waits with `Get-CimInstance` for
`Win32_PerfFormattedData_PerfOS_Processor` filtered by `Name='_Total'`; record the gate's UTC
start/end, each sample UTC, and `PercentProcessorTime`. Before registration, also repeat the read-only
budget/reserve, no-pending-run, process, absolute path and reparse-point checks. Failure of any gate
stops this campaign without retry or schedule rebase.

The corpus is the exact extracted source tree
`<作業フォルダー>\TaskArtifacts\UnLhaRe\01a0b076-4e26-7a71-ac35-32ed9259a871\egov-law-xml-candidate-inputs-20261016\input`
(100 files, 9,527,638 bytes; manifest SHA-256
`332cb1043efa84127312da055bb8c03104b991cb8e0820195cb2aafa4bfefee3`), supplied to each run as
`<作業フォルダー>\TaskArtifacts\UnLhaRe\goal-restore-20261019\egov-screen-20261020\input.zip`
(SHA-256 `861ce8956f8347b34223466d5fff93360d1901b6aa42cca1238965d590e73099`). The candidate is the
revision-10 `portfolio-trial` strategy. Run exactly 20 samples serially: rounds 0–9 each have one
`portfolio-trial` and one `7zip` sample; portfolio goes first on even rounds and 7-Zip first on odd
rounds. Round 0 is warmup; only rounds 1–9 contribute to medians. Do not launch the next registration
until the current run has completed the full Prunlet cleanup lifecycle and its recovery archive,
manifest, report, and receipts are preserved. Any failed sample, cleanup, measurement, CPU gate, or
fixed deadline stops the campaign; there are no retries.

Each run is fixed at 32 MiB / 512 entries / 300 seconds, preserving the abandoned-run recovery cap.
The worker also enforces 160 MiB per child and 60 seconds per timed command. Every timed command has
a fresh five one-second `_Total` CPU gate with a 15% ceiling and no wait-and-retry. The full campaign
wall limit is 1,800 seconds. 7-Zip 26.04 uses solid LZMA2 level 9, a 64 MiB dictionary, one create
thread and four extraction threads (`-t7z -mx=9 -m0=lzma2:d=64m -mmt=1 -ms=on -mqs=off -mtm=off
-mtc=off -mta=off`; extraction uses `-mmt=4`). A pass requires deterministic bytes for repeated
archives of each strategy, correct format checks and exact restoration, candidate archive size at
most 95% of 7-Zip, and candidate create and extract medians no slower than 7-Zip.

The fixed pins are:

| Artifact | SHA-256 |
| --- | --- |
| `aggregate-portfolio-7zip-product-screen.ps1` | `9ebe58ccca5586eff1505460239dbc9e4618fc53b5f6a6aaff13bbbeb5f9f78a` |
| `portfolio-7zip-product-screen.ps1` | `8789bad160e3dbdb1931267b80e4cd4da679cdc22d00f9b7e20f4417669e7a16` |
| `run-storage-experiment.ps1` | `aa981ad2dd416c10f14d6b2cc0b7e0d8b001de4e2ccfed7dc981ecd3b74e619b` |
| `storage-lifecycle.psm1` | `e3953d42595b66aba8a40da393e13bfd32e269b75c7d443e207dbfc9a202ba0c` |
| `disk-budget.ps1` | `506e4c68dc05734bc1a0c02bac6f81d4677e0bcffd9b9fa2b7bd67d53319bdcd` |
| Full `src/**/*.rs` source manifest | `0f549ab7f8c675b8ef241279d8ab29f90e9c7b7e32a5bc08c7effd0dc861c404` |
| Release x64 MSVC `unlhare-cli.exe` | `3dd0e0503ed6ec11c90ad1ff9ee69b2e34c564f8710871ab182dd684f27b7b4b` |
| 7-Zip 26.04 `7z.exe` | `95fff19b73eff77c87c0d7bd32822e43fb90dd2932459f962eb532d8dfb6ba53` |
| Input ZIP / extracted input manifest | `861ce8956f8347b34223466d5fff93360d1901b6aa42cca1238965d590e73099` / `332cb1043efa84127312da055bb8c03104b991cb8e0820195cb2aafa4bfefee3` |
| Campaign-start manifest | `1ec16512fc8b342407c391c80693598e506136f7b76dfff5e67d24df96e95afe` |

Register one sample at a time through the standard runner; change only `Round` and `Strategy` to
the next exact schedule entry. Example for round 0:

```powershell
$env:KHC_STORAGE_TASK_ID = 'goal-restore-20261019'
$screenParameters = @{
    CorpusProfile = 'eGovLawXml20261016'
    Round = 0
    Strategy = 'portfolio-trial'
    KhcExecutable = '<作業フォルダー>\UnLhaRe\goal-restore-20261019\cargo\x86_64-pc-windows-msvc\release\unlhare-cli.exe'
    SevenZipPath = 'C:\Program Files\7-Zip\7z.exe'
    InputRecoveryZip = '<作業フォルダー>\TaskArtifacts\UnLhaRe\goal-restore-20261019\egov-screen-20261020\input.zip'
}
& .\experiments\khc\run-storage-experiment.ps1 `
    -ScriptPath .\experiments\khc\portfolio-7zip-product-screen.ps1 `
    -ScriptParameters $screenParameters -MaxRunMiB 32 -MaxEntries 512 -TimeoutSeconds 300
```

Do not aggregate before the fixed deadline closes. After `2026-10-19T19:30:00Z`, call
`aggregate-portfolio-7zip-product-screen.ps1` with the exact 20 run IDs in registration order,
`CampaignStartedUtc` equal to the fixed `2026-10-19T19:00:00Z` marker, `CampaignFinishedUtc` equal to
the actual UTC time after the final Prunlet finalize, and the initial gate's start/end timestamps and
five CPU readings. It rejects early aggregation and checks all registrations across the entire
immutable start-to-deadline window (not merely through a caller-supplied finish time), so any extra
or failed in-window registration invalidates the set. Its result is written to
`<作業フォルダー>\TaskArtifacts\UnLhaRe\goal-restore-20261019\egov-screen-20261020\campaign-report.json`.
This development-only screen is not an independent holdout result or GOAL completion evidence.

#### e-Gov fixed product screen stopped before registration at the external CPU gate (2026-10-20)

The fixed campaign stopped during its initial external `_Total` CPU gate before any storage-run
registration. Samples 1–3 were 10%, 11%, and 10%; sample 4 was 31% at
`2026-10-19T19:01:22.3613469Z`, exceeding the preregistered 15% ceiling. The gate stopped on that
first failure, so sample 5 was not taken. No worker or 7-Zip command ran, no run ID was created, and
there are no compression, extraction, or size measurements. A read-only scan confirmed zero
registrations in the fixed campaign window and no campaign report. No cleanup was needed because no
run was registered. This is neither a candidate pass nor a codec no-go; do not retry this source/input
condition or relax the CPU threshold.

Preflight had passed the no-pending-run, 32 MiB budget-reserve, path/reparse, process, and all pinned
artifact checks. The exact failed gate and budget snapshot are retained at
`<作業フォルダー>\TaskArtifacts\UnLhaRe\goal-restore-20261019\egov-screen-20261020\pre-registration-stop.json`
(SHA-256 `75a1cc84649bcfe5b9fb48039f0ed7f5fe9b693be4c9c09d2f4f9c28e1356f5b`).

#### Schedule-replay Canterbury11 screen stopped before its first timed command (2026-10-20)

The single registration `6286e3c1acdf4f50a28b25b1dac330b0` used the source, input, 7-Zip,
worker, and runner pins above. It stopped at the screen worker's per-command CPU gate before
`0-portfolio-trial-create`: the one observed `_Total` sample was 32% at
`2026-10-19T17:22:35.6678372Z`, above the fixed 15% ceiling. The earlier external preregistration
gate `[3, 6, 2, 0, 0]%` had passed, but is not a substitute for this fresh gate. `Process.Start()`
was not reached (`exit_code=null`, `wall_ms=0`, no memory samples); only the untimed version probes
for 7-Zip and the CLI exited 0. The report has one partial sample, zero paired rounds, and
`candidate_decision=null`. The full Canterbury11 input manifest was validated, but no timed KHC
creation/extraction or 7-Zip comparison occurred. This is a CPU-gate interruption, neither a
candidate pass nor a format-level no-go. Do not retry this schedule-replay/Canterbury11 condition
or change the threshold; no performance or holdout result exists.

| Preserved artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| `portfolio-product-report.json` in `recovery.zip` | 16,823 | `813de0220a59eff0d52a17059d3d63cb8727831e8c77a43b15b39b821dd5d1bf` |
| `recovery.zip` | 1,159,521 | `e0267990f0c0a83f71987a2f29597716dd95c4bc525da5b697ad4795e01c71eb` |
| `recovery.json` | 4,048 | `b379a12a153f1a92963c6b536321ee8da58738e2330a19f5773da956e3f232d8` |
| `cleanup-request.json` | 5,070 | `9501b97a49e7df2be4c6896077d154221d6f3bd99ba7411158c8d7b10ec6645b` |
| `complete.json` | 1,592 | `3dd1a99d70df2c578dd0a95816c29abaec247593760861754c6d0c4be7c3af65` |
| `cleanup/delete-preview.json` | 3,356 | `a71451464f708a3977cae18a69a0030dd4d02efcf052546fc6c976874b0d9239` |
| `cleanup/delete-result.json` | 5,047 | `a475190756a2e12a610012e15cba9efbcdd2b553f7f9d181745625b9a49c8c90` |
| `cleanup/purge-preview.json` | 5,134 | `5c2dfb9af1de8df1b858b9cd724165e39c9b57439df7fa72dd58f0fd7d8d7562` |
| `cleanup/purge-result.json` | 5,081 | `f5a9b7145780f0e4fb0d582fe1a7a5d3f07b5c4c80794e0e52b0843996c05816` |

Prunlet operation `aea618299bc84d9d805758892f71e507` passed all staged cleanup validators. The
registered 16-entry tree measured 2,827,607 B; finalization records `BeforeBytes=2,827,607`,
`AfterBytes=0`, `State=complete`. The work path is absent, recovery evidence and receipts are intact,
and the post-cleanup read-only check found no pending lifecycle run or target process. Budget:
total 1,836,688,997 / 32,212,254,720 B, external 684,016,937 / 2,147,483,648 B, Cargo
1,625,357,095 / 6,442,450,944 B, lifecycle 190,572,106 / 1,073,741,824 B, reserve
304,087,040 B, and D-drive free space 529,884,196,864 B.

The outer runner, storage module and screen source hashes above are the preregistered values. Record
the final `STORAGE.md` hash in the research-selection entry before registration. Preserve the run
report and recovery evidence; use only the required staged Prunlet lifecycle for post-run cleanup.

### Revision-10 product-screen work-root correction and follow-up preregistration (2026-10-19)

The first registered run (`8d672b458eec4fc69aa17b7f2b2deed8`) stopped before any archive or timed
product command. The worker called `Check-Storage` before creating its registered work root;
`Check-Storage` enumerates that root, while `New-KhcStorageRun` only creates the lifecycle record.
The ensuing error report also could not be written because the root was absent. The run has zero
expected files, entries and bytes, no recovery ZIP, and no product samples. After verifying the work
root remained absent and the owner process had exited, `Finalize-KhcStorageRun` recorded the empty
run complete with `BeforeBytes=0`, `AfterBytes=0`; no deletion or Prunlet cleanup was required.

The worker now creates only the validated registered run root, as a direct child of its task root,
without `-Force`, before its first storage check. If root creation is unavailable, finalization
returns the original failure without attempting to save into the missing path. Final inventory,
report-write and post-write storage-check failures are retained as secondary error details and do
not replace the first failure. This changes only experiment harness setup/error reporting; the
codec, input, binaries, sample protocol, time/memory/storage limits and acceptance criteria remain
unchanged. The next registration is the sole corrected-harness follow-up, not a retry of the old
unchanged worker. A failure is a stop for this condition; do not retry it unchanged.

| Follow-up fixed input/tool | Bytes | SHA-256 |
| --- | ---: | --- |
| Canterbury11 raw input manifest / recovery ZIP | 2,810,784 / 8,765,120 | `bb63b0d70713c9aefa681347eaf99fb891d59f45923e009ad0deadc9ec9fc438` / `b74644fac5f89251b15a68db6b2a3bce1bd508c12f0f685a61cd5c96ae1540bb` |
| Release `unlhare-cli.exe` / 7-Zip 26.04 | 2,558,976 / 577,536 | `4f9fa4e293404c82335ace434271fd646ed62468fb32365d6fcf3e1d0641a403` / `95fff19b73eff77c87c0d7bd32822e43fb90dd2932459f962eb532d8dfb6ba53` |
| 37-file Rust source / 42-file Release build-input manifest | — | `034b15490a5c4a59ec1dcc3eb7c331df5be550ce0ab04fc99d7b52e30eaf06ac` / `85a8e995cbabb3ccf941b1995087c71374cc5bceadd42299237fd3fab4441c02` |
| Corrected `portfolio-7zip-product-screen.ps1` | 30,241 | `ce284ce0b506e635b604afa630ef9b9da01b415f7d869179c1b65551ea3e6d9c` |
| `run-storage-experiment.ps1` | 35,588 | `1b32ac958d00efbc66a31dd76d01ad597a3eae0b1a02dfc931d2f21090daaa24` |
| `storage-lifecycle.psm1` / `disk-budget.ps1` | 74,194 / 2,004 | `9686b6b258b4fc7b64e538dda7d32a0c3a355dbfa3ce12daa801395e51f942a0` / `506e4c68dc05734bc1a0c02bac6f81d4677e0bcffd9b9fa2b7bd67d53319bdcd` |

All compression inputs, tool/build pins, alternating 1+9 rounds, per-command gates and the 128 MiB /
512-entry / 1,800-second registration remain exactly as in the preceding preregistration. Recheck
all hashes, CPU, processes, pending lifecycle records and storage budgets immediately before the
single follow-up registration. Record the final `STORAGE.md` SHA-256 in the research-selection
amendment before launching it; retain its report and recovery evidence under the registered
lifecycle paths.

### Pre-registration stop: portfolio-screen wrapper pin mismatch (2026-10-19)

The first attempt to register the corrected worker was rejected by the wrapper's fixed worker-SHA
check before `New-KhcStorageRun`. The wrapper still pinned the preceding worker SHA
`7dcab75d9811dc1b5af8bb23d4594995de3a2e3ed290a679643a9eb8a01203b7`, while the corrected worker
is `ce284ce0b506e635b604afa630ef9b9da01b415f7d869179c1b65551ea3e6d9c`. No run record, work root,
archive, timed command or sample was created; the lifecycle record count remained 16 and no cleanup
was required. This is a pre-registration stop, not product-performance evidence.

The wrapper now replaces that one exact allowlisted worker SHA with the corrected SHA. Its generic
registration limits, screen-specific 128 MiB / 512-entry gate, path checks and all other pins are
unchanged. The wrapper SHA is now
`83bb8f1e29b9a732b224dd89fb50e90b3e13fc7a5f18376de2eeba12ca80a361` (35,588 B); the screen worker
remains 30,241 B with SHA
`ce284ce0b506e635b604afa630ef9b9da01b415f7d869179c1b65551ea3e6d9c`. Treat the rejected attempt as
closed; the only next step is one new registration with this exact wrapper/worker pair and a fresh
pre-run check. If that preregistration or its execution fails, stop without repeating it unchanged.

### Revision-10 product-screen partial memory-counter correction (2026-10-19)

Before the remaining follow-up registration, an independent review found that an untimed version
or archive-list command skipped *all* memory recording and limit checks when any one counter was
missing. The worker now records and checks every positive working-set, paged-memory and private
byte value independently, lists missing counter fields, and reports partial sampling accurately.
The timed create/extract path still rejects missing required counters and a missing positive private
sample; the per-command 160 MiB limit, polling cadence, timeout, CPU gate, output bounds, inputs,
arguments, acceptance criteria and outer registration limits are unchanged. No registration or
product command was run after this correction.

| Corrected registration pin | Bytes | SHA-256 |
| --- | ---: | --- |
| `portfolio-7zip-product-screen.ps1` | 32,024 | `57f85cc3fda72ca940d5a28c909bea592cbc64705a76886c4a05343e1b376b8b` |
| `run-storage-experiment.ps1` | 35,588 | `d78c09bccd36bc509029e49687d6305922517c7fb9d226bc83b57bd33076b470` |

The wrapper's only change since the preceding pin is its screen-specific worker SHA. The preceding
wrapper-pin rejection remains a closed pre-registration stop; no run record, work root or product
sample was created by it. One registration remains authorized after a fresh full pre-run check of
this exact worker/runner pair, all source/tool/input pins, lifecycle state, storage budgets, process
inventory and the five-reading CPU gate. Record the resulting storage-document SHA in the research
selection before starting; any failed check stops without repeating it unchanged.

### Revision-10 product-screen live-memory sample accounting correction (2026-10-19)

The single follow-up using the per-counter worker (`9df233fe994b4af08db05acbf666bfc9`) failed in the
first `portfolio-trial` create command. The child exited 0 after 2,257.1765 ms (2,187.5 ms CPU),
with reported peak working set 24,637,440 B, peak paged memory 20,893,696 B, sampled private-memory
maximum 16,224,256 B, and 62 complete positive memory observations. The worker nevertheless recorded
`Missing memory counter: 0-portfolio-trial-create`, all three counter names as missing, and partial
sampling. The report did not retain each poll's process-exit state, so a post-exit polling race is a
plausible cause, not a confirmed observation. One archive was written (450,309 B,
SHA-256 `2d7314dc55ac9d7b8c1684f10fee497ecb2cc5822f6de506372da17a429df447`), but the worker stopped
before validating its format, size, or determinism and before any test, extract, or restored-manifest
comparison. This attempt has no candidate comparison or product-performance result.
This registered run supersedes the earlier per-counter entry's "not yet run" status; that statement
accurately described the state when it was written.

The registered work tree was removed through the required staged Prunlet protocol (operation
`de744027ac614c97ad0188b05597bcce`, 17 entries, 3,278,234 B before and 0 B after). Its recovery
evidence remains at
`<作業フォルダー>\TaskArtifacts\UnLhaRe\goal-restore-20261019\storage-lifecycle\runs\9df233fe994b4af08db05acbf666bfc9\recovery.zip`
(1,633,014 B, SHA-256 `8eebe511df28780e921666e5fb87f20649d9da7a5d6bd3c055da303b86d71575`); the recovery
manifest SHA-256 is `9df79ded9e8f16282851aeb3f678e95ee3378c80b6dd0d95e3032271d99ec6f0`.

The worker now counts `live_memory_samples` separately. A sample counts as live only when all three
counters are positive and the process is confirmed alive immediately before and after their read.
Timed commands require at least one such complete live sample and positive maxima for working set,
paged memory, and sampled private bytes. Missing counters while the child is still running remain
fatal. Missing counters after exit are reported separately and tolerated only if a complete live
sample was already recorded; every positive counter reading continues to be checked independently
against the 160 MiB ceiling. This is a measurement-harness correction only; codec, input, command
arguments, resource limits, timing protocol, and acceptance criteria are unchanged.

| Follow-up harness pin | Bytes | SHA-256 |
| --- | ---: | --- |
| `portfolio-7zip-product-screen.ps1` | 33,153 | `de1ddd49dd0f0ba5606c1d247839387337ae3e0d94e3c0eff65b658a1c32eac1` |
| `run-storage-experiment.ps1` | 35,588 | `4815a60909cb1265496fbd1ce5f637a533cf91f6dc5a9bec844d32f83cbc0258` |

One registration with this exact worker/runner pair may proceed after a new full pre-run check of
all input, source, executable and lifecycle pins, process inventory, storage budgets, and the
five-reading CPU gate. Record the updated `STORAGE.md` hash in the research selection before
launching. If preregistration or execution fails, do not repeat it unchanged.

### Revision-10 fixed product-screen internal CPU-gate stop (2026-10-19)

The single follow-up registration used the corrected worker SHA-256
`de1ddd49dd0f0ba5606c1d247839387337ae3e0d94e3c0eff65b658a1c32eac1` and runner SHA-256
`4815a60909cb1265496fbd1ce5f637a533cf91f6dc5a9bec844d32f83cbc0258`, with the fixed
128 MiB / 512-entry / 1,800-second envelope. The fresh external five-sample CPU gate passed at
`[1.7, 2.9, 0, 2.2, 2.2]%` (maximum 2.9%).

The run completed only the round-0 warmup work before stopping. `portfolio-trial` create exited 0
in 2,170.7152 ms and its extraction exited 0 in 183.7837 ms with the restored manifest verified;
its archive was 450,309 B (SHA-256
`48d1075cc2d7e6d2a89863f7e7376c9a3f534c5dc7fa89d88b6265c582dc622b`). 7-Zip archive creation
exited 0 in 745.9333 ms and wrote 483,599 B (SHA-256
`ea8b4b785c245001ab0efb5aa0a21d0339cdf74d8d62d5ccdee75b5f1b8e4299`). Before the first
`0-7zip-extract` command, the screen's internal `_Total` CPU gate stopped at 16% over its 15%
limit. The gate had two readings before stopping: 1% at `2026-10-19T14:01:56.3430336Z`, then
16% at `2026-10-19T14:01:57.6296516Z`; the 7-Zip extract was not launched. No measured paired
round completed. The report has an empty summary, null candidate pass/decision fields, and states
that holdout and general superiority were not evaluated. These warmup archives are not product
performance evidence or a candidate decision. Do not retry this condition unchanged.

The failed registered run is `039411b01e4c49f0a7c18b475b58f462`, with work directory
`<作業フォルダー>\UnLhaRe\goal-restore-20261019\run-0f414a07d8334115b653d6ea31d9a8b5`. Its report
is retained inside the recovery ZIP; report SHA-256 is
`c69a0d26830f9a07bee0867bcb4735d85d9e5ed2f11eb7ac0466f97b99c8ff9d`. The 30-entry / 25-file
inventory measured 6,595,431 B. Staged Prunlet delete-preview, delete, purge-preview and purge
apply all passed (operation `19d09c148c68416eb518a302c006a57d`); `complete.json` records
`BeforeBytes=6,595,431`, `AfterBytes=0`, and the work directory is absent. The recovery ZIP remains
at `<作業フォルダー>\TaskArtifacts\UnLhaRe\goal-restore-20261019\storage-lifecycle\runs\039411b01e4c49f0a7c18b475b58f462\recovery.zip`
(3,299,468 B, SHA-256
`34731667812c2fe8c5808071f10082b5e085aeae267e4d354ed05473a7012962`); `recovery.json` SHA-256
is `79ac8ac216e5d1f10bf580bc69ab05f1936c6ea96fb9838b393672e6e225b2c0`.

This execution stop closes the one authorized follow-up for this exact condition. It does not
establish a compression or speed result, and it does not achieve the broader GOAL.

### Revision-10 final-candidate frame-reuse E2E preregistration (2026-10-19)

The `PortfolioTrial` encoder now returns the already encoded `RecordAdaptiveTrial` frame when it is
strictly smaller than every earlier candidate. This avoids one deterministic re-encode while
preserving the MDL → KCS1 → KRS2 → KRS3 strict-size/tie order. Only the final candidate may be
returned directly, so no retained frame overlaps a later codec workspace. This is not a format or
decoder change. The E2E must reconfirm deterministic candidate frames, exact strict-minimum
selection, API/CLI archive checks, byte-exact extraction, invalid-frame rejection and revision
compatibility. This is correctness evidence only; it provides no speed, memory or 7-Zip comparison.

| Pre-run artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| `src/khc/mod.rs` | 35,762 | `4777b32d96973312b5fe379a11e61acf740bb92c8a52eddff039409baa7685f0` |
| 37-file Rust source manifest | — | `1e215cc07f044f0758b30ef05dd59dc6855e42e473a6dc453484314e486a7c5a` |
| Release `unlhare-cli.exe` | 2,558,976 | `871308ae01e39e44bb5ad2d9c2dc4fe059fff6f46a48b9accd50688423d309ef` |
| Release `khc_spatial_mdl_e2e.exe` | 1,648,128 | `4ac4408471293847ff61ce5fcbd90775ac3fceb5496cd888413170c7e934d64f` |
| `spatial-mdl-e2e.ps1` | 11,596 | `099153c0493f6e8d1736f52cebdbf044c50baf64f0310c55f0bcdb0ab0177b8b` |
| `run-storage-experiment.ps1` | 35,588 | `4815a60909cb1265496fbd1ce5f637a533cf91f6dc5a9bec844d32f83cbc0258` |
| `storage-lifecycle.psm1` / `disk-budget.ps1` | 74,194 / 2,004 | `9686b6b258b4fc7b64e538dda7d32a0c3a355dbfa3ce12daa801395e51f942a0` / `506e4c68dc05734bc1a0c02bac6f81d4677e0bcffd9b9fa2b7bd67d53319bdcd` |
| pinned ptt5 recovery ZIP | 769,634 | `882e7108870c3de5d20de6e87ffc89f390c5d34630930aef73baed9171557f75` |

Register one run with `spatial-mdl-e2e.ps1`, the exact pinned input and D-drive Release binaries,
`ChildTimeoutSeconds=240`, and outer limits 8 MiB / 96 entries / 300 seconds. The Release Cargo
output said `Finished`, but the serial wrapper returned 1 because a `VCTIP.EXE` process remained
in its job after the drain grace; its artifact hashes are pinned above, and this E2E is not a
performance run. Confirm no Cargo, rustc, CLI or E2E process is active and rerun the lifecycle
budget/process checks before registration. If registration or execution fails, do not retry this
condition unchanged. Preserve prior run records and their fixed hashes.

### Completed revision-10 final-candidate frame-reuse correctness E2E (2026-10-19)

The preregistered run `734aac55e9064d22abe8de2d5b2553e8` completed with outer exit code 0. Its
API E2E reported revision 10, eight frame families, nine malformed archives rejected, legacy
revisions 1–9 readable, the memory-reservation guard exercised, and a 43,218 B API archive. The
CLI created revision 10, listed/tested/extracted two files (513,225 B total), and restored the
ptt5 member with the pinned SHA-256. The full report has 34 child-command records; the 20
nonzero child exits were expected no-replace and invalid-archive rejections, and the E2E driver
passed all assertions. This is correctness/compatibility evidence only, not a performance or
memory measurement.

The lifecycle cleanup request measured 89 entries / 5,453,097 B. Direct installed Prunlet
recursive delete and purge completed as operation `a3443ea3192944e1b398babe08af47a9`; the
lifecycle record is complete with `BeforeBytes=5,453,097`, `AfterBytes=0`, and the work root absent.
The recovery evidence is retained at
`<作業フォルダー>\TaskArtifacts\UnLhaRe\goal-restore-20261019\storage-lifecycle\runs\734aac55e9064d22abe8de2d5b2553e8\`:
`recovery.zip` 746,804 B, SHA-256
`8719fd8458ab3f2db3043aed34f4359b2f16cfc44bc59182dac76b6556f0ed41`; `recovery.json` 21,644 B,
SHA-256 `6d66e96231a5dd4d565437a904d50d78f224ebb6c4d6d1ff075d802c5255a9c2`; report 7,162 B,
SHA-256 `e5e83627350791b612cfd30920c90dba72a22eef1980dc2f090fca3f32d3cdf9`. No benchmark
acceptance criterion or prior screen result is changed by this E2E.

### Revision-10 MDL-last candidate-order frame-reuse E2E preregistration (2026-10-19)

The trial now evaluates complete frames in the order KCS1, KRS2, KRS3, MDL while keeping explicit
selection ranks MDL, KCS1, KRS2, KRS3. This preserves the prior minimum-size and tie result while
allowing the already encoded MDL frame to be returned directly when it wins (including a tie).
When another strategy wins, it is still re-encoded after comparison so no retained frame overlaps
a later bounded codec workspace. This changes no frame format or decoder behavior. The preceding
Canterbury11 warmup archive contained 10 MDL blocks and one KCS1 block; that distribution motivated
the ordering experiment but is not performance evidence. This one registered E2E compares portfolio
frames with deterministic candidate encodings under the strict-size rule and MDL-first tie order; it
also checks revision compatibility, malformed-archive rejection and byte-exact API/CLI extraction.
It is correctness evidence only, not a speed, memory or 7-Zip result.

| Pre-run artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| `src/khc/mod.rs` | 35,967 | `6480aefb755ccd2c1130551e89415613236449302e19b60bcd1249c18570315c` |
| 37-file Rust source manifest | — | `a404c2bfb8b32351047f323f5fb27a96912c43837efddf0cea4af98c1a3daac9` |
| Release `unlhare-cli.exe` | 2,558,464 | `68dc727aac15b99fccf3dcd3d42c39a8c6e1ca6f470959ab57935867e816fbe7` |
| Release `khc_spatial_mdl_e2e.exe` | 1,648,128 | `0bab2e31b0b003ba5b224f299b8557ab1c3dda97ffe15667b6ddcd482f6ff0e4` |
| `spatial-mdl-e2e.ps1` | 11,596 | `099153c0493f6e8d1736f52cebdbf044c50baf64f0310c55f0bcdb0ab0177b8b` |
| `run-storage-experiment.ps1` | 35,600 | `2d06d50fb7ee2d1ef71e3dbc4f3420210a099f22afa2119f5862c9146dc49afe` |
| `storage-lifecycle.psm1` / `disk-budget.ps1` | 74,194 / 2,004 | `9686b6b258b4fc7b64e538dda7d32a0c3a355dbfa3ce12daa801395e51f942a0` / `506e4c68dc05734bc1a0c02bac6f81d4677e0bcffd9b9fa2b7bd67d53319bdcd` |
| pinned ptt5 recovery ZIP | 769,634 | `882e7108870c3de5d20de6e87ffc89f390c5d34630930aef73baed9171557f75` |

The latest Release build completed through `run-serial-cargo.ps1` with wrapper exit 0, and
`unlhare-cli --version` reported `unlhare 1.0.4`. Before registration, the lifecycle module's
read-only `Assert-KhcStorageBudget -ReserveBytes 25165824` check passed for the fixed 8 MiB / 96
entry run plus its 24 MiB reservation. Register exactly one `spatial-mdl-e2e.ps1` run with the
pinned recovery ZIP and D-drive Release binaries, `ChildTimeoutSeconds=240`, and outer limits
8 MiB / 96 entries / 300 seconds. If registration or execution fails, do not retry this exact
condition unchanged. Preserve all earlier pins, runs and acceptance criteria.

### Completed revision-10 MDL-last candidate-order correctness E2E (2026-10-19)

The one preregistered run `0b371cf18d2f4165840a9995ef00f9ed` passed with outer exit code 0. The API
E2E reported revision 10, eight frame families, nine malformed archives rejected, legacy
revisions 1–9 readable, and the memory-reservation guard exercised. The CLI created, listed,
tested and extracted a revision-10 archive; the two restored files totaled 513,225 B and matched
their exact source hashes. The report contains 34 check records; its 20 nonzero CLI exits are the
expected no-replace and malformed-archive rejection cases. The 40,051 B CLI archive SHA-256 is
`730552fc98858abbc101605e6e937b45e73798bd01e94e317ff23f2d2922f64a`. This verifies correctness
and compatibility only, not speed, memory usage or 7-Zip superiority.

The lifecycle cleanup measured 89 entries / 5,453,097 B. Direct installed Prunlet delete and purge
completed as operation `c69e6740df95451b938df9734f6d3ea8`; the lifecycle record is complete with
`BeforeBytes=5,453,097`, `AfterBytes=0`, and the work root absent. Recovery evidence remains at
`<作業フォルダー>\TaskArtifacts\UnLhaRe\goal-restore-20261019\storage-lifecycle\runs\0b371cf18d2f4165840a9995ef00f9ed\`:
`recovery.zip` 746,812 B, SHA-256
`ceb828d289d6d7b5bc955ab7e3ad4bb6eafe41116c01d4a240474526c166991b`; `recovery.json` 21,644 B,
SHA-256 `aba3da2d9f98f0695150692ae3eb82c4d0ae3513d217040dc8c85a65b0f60106`; report
`spatial-mdl-e2e.json` 7,162 B, SHA-256
`60c07ebcfc99fa9d2b6dd61eeb2e5f23e6f4ccb9b78a92c642f7f836f5f965ad`. Post-cleanup verification
found all 21 lifecycle records complete, no pending run or target process, and the recovery ZIP,
manifest and report hashes intact. No performance-screen acceptance criterion changed.

### Revision-10 MDL-last Canterbury11 product-screen preregistration (2026-10-19)

This is one new development-only screen for the current MDL-last source after its revision-10
correctness E2E passed. It is not an unchanged retry of run `039411b01e4c49f0a7c18b475b58f462`:
that earlier candidate stopped before measured rounds at the internal CPU gate, and the current
candidate order/source manifest and Release CLI are different. The earlier stop is neither a
candidate pass nor a no-go. Canterbury11 remains a development corpus, not a holdout; this screen
cannot establish general superiority or complete the GOAL.

| Fixed pre-run artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| Canterbury11 manifest (11 files) | 2,810,784 total | `bb63b0d70713c9aefa681347eaf99fb891d59f45923e009ad0deadc9ec9fc438` |
| retained recovery ZIP | 8,765,120 | `b74644fac5f89251b15a68db6b2a3bce1bd508c12f0f685a61cd5c96ae1540bb` |
| current 37-file Rust source manifest | — | `a404c2bfb8b32351047f323f5fb27a96912c43837efddf0cea4af98c1a3daac9` |
| Release `unlhare-cli.exe` (`unlhare 1.0.4`) | 2,558,464 | `68dc727aac15b99fccf3dcd3d42c39a8c6e1ca6f470959ab57935867e816fbe7` |
| 7-Zip 26.04 `7z.exe` | 577,536 | `95fff19b73eff77c87c0d7bd32822e43fb90dd2932459f962eb532d8dfb6ba53` |
| `portfolio-7zip-product-screen.ps1` | 33,153 | `8ceccd69f9aff77492fd36a809981e71df7cf745f4b780a3d422226c1d6c1449` |
| `run-storage-experiment.ps1` | 35,600 | `825fb8ca8425779d0bed2d0dc7001889d052444571f05a4c2573338e03faf980` |
| `storage-lifecycle.psm1` / `disk-budget.ps1` | 74,194 / 2,004 | `9686b6b258b4fc7b64e538dda7d32a0c3a355dbfa3ce12daa801395e51f942a0` / `506e4c68dc05734bc1a0c02bac6f81d4677e0bcffd9b9fa2b7bd67d53319bdcd` |
| `Cargo.toml` / `Cargo.lock` | 1,414 / 30,555 | `3b47e50b8e543a5af82617bee4d4bd48ec20fc795a333ba50cbc9e439e0c2fac` / `d8dab69b03805b559440c186ed04c2d0d0ee57eba922306cfa6827bf79985554` |

The screen's pinned protocol remains unchanged: one warmup and nine measured alternating paired
rounds; full archive creation and filesystem extraction; exact eleven-file restore; deterministic
archive bytes; 7-Zip 26.04 using solid LZMA2 level 9, 64 MiB dictionary and one thread; five fresh
one-second `_Total` CPU readings no greater than 15% before each timed command; 60 seconds and
160 MiB per child; and 128 MiB / 512 entries / 1,800 seconds outer limits. The candidate passes
this development screen only if its archive is at most 95% of 7-Zip's and both candidate create
and extract wall-time medians are no slower than 7-Zip. A failed precondition or CPU gate is a
stop, not permission to retry unchanged or loosen any threshold.

Before exactly one registration, verify the table pins, no pending lifecycle run or target process,
and the read-only storage budget for the registered screen; immediately take five fresh external
CPU readings, all at or below 15%. Use the fixed command and parameters in the preceding Canterbury11
pre-registration, with the same pinned input ZIP and D-drive Release executable. Preserve recovery
evidence and clean the registered work tree only through the required Prunlet lifecycle. Record
the final `STORAGE.md` SHA-256 in the research-selection amendment before starting the run.

### Revision-10 MDL-last Canterbury11 screen CPU-gate stop and cleanup (2026-10-20)

The single preregistered run `80bcc521be924a2d9f5a9671dfa042e7` registered after five external
`_Total` CPU readings `[0, 3, 0, 8, 5]%` (maximum 8%). It reached only part of the round-0 warmup:
PortfolioTrial create/extract passed and restored the exact 2,810,784-byte input; the KHC archive
was 450,309 B (`15ce3a9e426fee9d2651c611d692d35118eb671169460e754d663c83c0304b8d`). 7-Zip archive
creation also passed at 483,599 B (`ea8b4b785c245001ab0efb5aa0a21d0339cdf74d8d62d5ccdee75b5f1b8e4299`).
Before `0-7zip-extract`, the worker's fresh internal CPU gate observed 31% at
`2026-10-19T14:57:13.6649143Z`, above the fixed 15% threshold, and stopped with “no retry.” 7-Zip
extraction and all measured paired rounds were not run. The report status is `failed`, summary is
empty, and every candidate decision field is null. These warmup observations are not valid
performance samples and imply neither screen pass nor candidate no-go. Do not repeat this exact
screen condition or loosen its CPU gate.

| Preserved run evidence | Bytes | SHA-256 |
| --- | ---: | --- |
| Recovery ZIP | 3,299,395 | `94da7d9fb40e62682defc8bf923b3069ecae1d9d7ffc18b53b45d6682b43d22f` |
| Recovery manifest | 7,906 | `de6231e5532a95a199d53a599d4f4a743c09fc02c8972f0578dfbf9d4b2adaa0` |
| `portfolio-product-report.json` in recovery ZIP | 39,831 | `30531dcda80fc14128508285ae06c7abf1a5fcdf865d81f8155b58b017543896` |

The 6,595,307-byte work tree (25 files; 30 entries including directories) was removed and its
Prunlet backup purged through the installed CLI in CMD, after verified delete and purge previews
of 30 items. Operation
`62ee01f84b14471fab7d76ebcc3d6f54` completed the lifecycle record with `BeforeBytes=6,595,307`,
`AfterBytes=0`; the registered work root is absent. Post-cleanup checks found all 22 lifecycle runs
complete, no target process and the preserved evidence hashes intact. The development screen has
no performance result and does not satisfy the required holdout or GOAL completion criteria.

### KRS2/KRS3 shared-preparation revision-10 correctness E2E preregistration (2026-10-20)

The current PortfolioTrial implementation shares the legacy baseline and voter-position schedule
between the KRS2 and KRS3 length evaluations. Each candidate frame is discarded before the next
bounded coder runs; the existing rank and fallback behavior are intended to remain unchanged.
This is a finite correctness/compatibility check, not a performance result or an independent
compression-method claim. The earlier MDL-last E2E and Canterbury11 screen pins do not describe
this source revision.

| Fixed pre-build artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| 37-file `src/**/*.rs` manifest | — | `76521abb786b256dab218f1e555a216d4a82b53eeda28f06ee800e765543e172` |
| 42-file Rust build-input manifest, including the E2E example | — | `4090db4055f4849711ed215f088ba25d944227fce43c5b6bde03d3e9fea75981` |
| `src/khc/record.rs` | 35,507 | `5d400ecf099623073ee7942e17febb693748c147fd55a06730eb0aeb095d43db` |
| `src/khc/mod.rs` | 36,061 | `4613ed1e1fdcbdfe5ece704e47ecff23213e5621a4b6c0839f02712e155da7f3` |
| `examples/khc_spatial_mdl_e2e.rs` | 22,744 | `9d834c3c255fe2e14b920c47fca309bb1cb8d4e517b19ffc4221ede6faffd07c` |
| `spatial-mdl-e2e.ps1` | 11,596 | `099153c0493f6e8d1736f52cebdbf044c50baf64f0310c55f0bcdb0ab0177b8b` |
| `run-serial-cargo.ps1` / `run-storage-experiment.ps1` | 9,859 / 35,600 | `053532f8fa0266b23a6dcc02e60bfb54e94d5d58d874a71692df51dec16a158f` / `825fb8ca8425779d0bed2d0dc7001889d052444571f05a4c2573338e03faf980` |
| `storage-lifecycle.psm1` / `disk-budget.ps1` | 74,194 / 2,004 | `9686b6b258b4fc7b64e538dda7d32a0c3a355dbfa3ce12daa801395e51f942a0` / `506e4c68dc05734bc1a0c02bac6f81d4677e0bcffd9b9fa2b7bd67d53319bdcd` |
| `Cargo.toml` / `Cargo.lock` | 1,414 / 30,555 | `3b47e50b8e543a5af82617bee4d4bd48ec20fc795a333ba50cbc9e439e0c2fac` / `d8dab69b03805b559440c186ed04c2d0d0ee57eba922306cfa6827bf79985554` |
| recovery ZIP `runs/8a849a3267954242bcd8424b93526176/recovery.zip` | 769,634 | `882e7108870c3de5d20de6e87ffc89f390c5d34630930aef73baed9171557f75` |

The pinned ZIP member is `input/ptt5` (513,216 bytes; SHA-256
`0ec3a75089bb52342813496b17e51377bc9eba3cb519a444d67025354841d650`). Before build, the
Release CLI and E2E binaries on the D-drive target were the older MDL-last artifacts
(`68dc727a…` and `0bab2e31…`); they must not be used for this source revision. First run
`rustfmt --check --edition 2024` on `record.rs`, `mod.rs`, and the E2E example, then build only the
Release CLI and E2E example through `run-serial-cargo.ps1` with `TransientMiB=256` and Cargo
arguments `build --locked --offline --release --target x86_64-pc-windows-msvc --bin unlhare-cli
--example khc_spatial_mdl_e2e`. Cargo target, TEMP/TMP and intermediate output remain under
`<作業フォルダー>\UnLhaRe\goal-restore-20261019`; no repo-local build output is part of this run.

After verifying the new binary hashes and the unchanged source/build manifests, register exactly
one `spatial-mdl-e2e.ps1` run with its pinned recovery ZIP and those D-drive Release binaries,
`ChildTimeoutSeconds=240`, and the fixed outer cap of 8 MiB / 96 entries / 300 seconds. The
PowerShell runner, E2E script, source tree, build inputs, input ZIP, and lifecycle budget helper
must still match the table before registration; record the materialized binary hashes here and
in the research selection before starting the run. The read-only budget check before this
preregistration passed: total 1,803,777,490 / 32,212,254,720 B; Cargo 1,597,694,515 /
6,442,450,944 B; lifecycle 185,323,179 / 1,073,741,824 B; external 651,105,430 /
2,147,483,648 B; 268,435,456 B reserved for Cargo; D-drive free space 536,867,004,416 B; no
target process was active. If build, registration or E2E fails, preserve its failure evidence and
do not retry this exact condition unchanged. Update both additive records with the actual outcome;
do not infer speed, memory improvement, superiority or GOAL completion from correctness alone.

#### Materialized Release artifacts and bounded wrapper confirmation (2026-10-20)

The pinned 42-file build-input manifest remained unchanged. The first serial Release build compiled
successfully (`Finished` in 44.73 s) and produced the artifacts below, but `run-serial-cargo.ps1`
returned 1 because its drain check still saw one `VCTIP.EXE` job process (PID 1384). The process
was absent at the next read-only process check; no Cargo, rustc, CLI, E2E, or task-root process
remained. One bounded confirmation build through the same wrapper completed in 0.10 s and returned
0; no further retry is authorized for this build condition.

| Release artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| `unlhare-cli.exe` (`unlhare 1.0.4`) | 2,560,000 | `1742b3e28e70b1a2c105ce3c0268332c712a97b0f94a3fda717809859cc81064` |
| `khc_spatial_mdl_e2e.exe` | 1,650,176 | `b9aacd015e7b288339c4b74f7085b2ac6b2feadf361662551c7a526fc490b0c3` |

Use only these binaries for the single preregistered E2E. The post-build storage preflight passed
with total 1,803,794,990 / 32,212,254,720 B, Cargo 1,597,717,015 / 6,442,450,944 B, lifecycle
185,323,179 / 1,073,741,824 B, external 651,122,930 / 2,147,483,648 B, 25,165,824 B reserved,
and no target process. These figures are the post-build check; repeat the read-only budget and
process checks immediately before registration. The current `STORAGE.md` SHA-256 must be cited
in the research selection before the E2E is registered.

### Completed KRS2/KRS3 shared-preparation revision-10 correctness E2E (2026-10-20)

The one fixed 8 MiB / 96-entry / 300-second registration was run as
`15296b966ea04dfa80d63ce4a8a62b54`, using `spatial-mdl-e2e.ps1` and a 240-second child timeout.
The source/build manifests and Release CLI/E2E hashes matched the preceding preregistration.
The report contains 34 child checks; all matched their expected exit behavior (14 successful
commands and 20 intentional no-replace/invalid-archive rejections). The API E2E created revision
10 with 8 frames, exercised all five allowed frame-family groupings, rejected 9 malformed
archives, read revisions 1–9, and tested the memory-reservation guard. The CLI created, listed,
tested and extracted a two-file archive (513,225 bytes); exact `ptt5` and short-file hashes were
restored, while existing-output and malformed-input checks were rejected as expected. This is
correctness/compatibility evidence only, not a timing, memory, 7-Zip, or holdout result.

| Preserved result evidence | Bytes | SHA-256 |
| --- | ---: | --- |
| E2E report `spatial-mdl-e2e.json` | 7,162 | `7c93e16bef19c67f807f20a355386225dd37678757ce7dc25d7b8474a084d108` |
| revision-10 CLI archive | 40,051 | `83b474b04fc269f5f77ed159b0e86df5a2be76bc2146ccaaa5aca613ac3837f6` |
| recovery ZIP | 746,808 | `a9755812accd161382f27510bae936836f2c96fd714357f4e736d16d653e2f2a` |
| recovery manifest | 21,644 | `0bcc7fe0b7bdc8b8c7bf2d2437c141baa64d40afacbfdf45d2ca1c93dacc0bbb` |

The outer PowerShell call reported exit 1 only because its added post-call guard checked
`$LASTEXITCODE` after invoking a PowerShell script, where that variable was unset. The storage
runner emitted the normal `awaiting-prunlet` result, and the saved report and lifecycle record
show no E2E error; the outer guard did not trigger a rerun. The resulting work tree was 5,453,097
B across 74 files and 15 directories. The installed Prunlet CLI in direct CMD deleted exactly
those 89 previewed entries (no errors), then purged 74 backed-up files after a verified purge
preview; 15 directory entries were correctly `not_backed_up`. Operation
`26ad625368e345029aecc582b4ac8de6` completed lifecycle run `15296b966ea04dfa80d63ce4a8a62b54`
with `BeforeBytes=5,453,097`, `AfterBytes=0`; the work root is absent. The recovery ZIP and
manifest above remain in TaskArtifacts. All 23 lifecycle runs are complete, no target process is
active, and the post-cleanup budget passed: total 1,804,697,136 / 32,212,254,720 B; Cargo
1,597,712,015 / 6,442,450,944 B; lifecycle 186,225,325 / 1,073,741,824 B; external
652,025,076 / 2,147,483,648 B; D-drive free space 536,855,887,872 B.

### Shared-preparation revision-10 Canterbury11 / 7-Zip product-screen preregistration (2026-10-20)

After the revision-10 shared-preparation correctness E2E passed, prepare one separate
development-only product screen for the same source revision. The prior Canterbury11 run
`80bcc521be924a2d9f5a9671dfa042e7` remains a CPU-gate stop with no measured paired rounds; this
is a new candidate source/binary condition, not a retry of its unchanged MDL-last build. No
performance claim follows unless the complete fixed screen succeeds.

| Fixed pre-run artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| Canterbury11 manifest (11 files; 2,810,784 B total) | — | `bb63b0d70713c9aefa681347eaf99fb891d59f45923e009ad0deadc9ec9fc438` |
| retained Canterbury11 recovery ZIP | 8,765,120 | `b74644fac5f89251b15a68db6b2a3bce1bd508c12f0f685a61cd5c96ae1540bb` |
| current 37-file `src/**/*.rs` manifest | — | `76521abb786b256dab218f1e555a216d4a82b53eeda28f06ee800e765543e172` |
| Release `unlhare-cli.exe` (`unlhare 1.0.4`) | 2,560,000 | `1742b3e28e70b1a2c105ce3c0268332c712a97b0f94a3fda717809859cc81064` |
| 7-Zip 26.04 `7z.exe` | 577,536 | `95fff19b73eff77c87c0d7bd32822e43fb90dd2932459f962eb532d8dfb6ba53` |
| `portfolio-7zip-product-screen.ps1` | 33,153 | `a760817de5588b53657212fda0673b1b56999754717c43c66c84e87685d6e73a` |
| updated `run-storage-experiment.ps1` | 35,610 | `743022bfba309f887ed647c65c51b05670a27138b7fa5197ca62b750a7778ebe` |
| `storage-lifecycle.psm1` / `disk-budget.ps1` | 74,194 / 2,004 | `9686b6b258b4fc7b64e538dda7d32a0c3a355dbfa3ce12daa801395e51f942a0` / `506e4c68dc05734bc1a0c02bac6f81d4677e0bcffd9b9fa2b7bd67d53319bdcd` |
| `Cargo.toml` / `Cargo.lock` | 1,414 / 30,555 | `3b47e50b8e543a5af82617bee4d4bd48ec20fc795a333ba50cbc9e439e0c2fac` / `d8dab69b03805b559440c186ed04c2d0d0ee57eba922306cfa6827bf79985554` |

The existing screen worker and acceptance contract remain fixed: one warmup followed by nine
alternating paired rounds; full archive creation and filesystem extraction; exact restore of all
11 files and deterministic candidate bytes; 7-Zip 26.04 solid LZMA2 level 9, 64 MiB dictionary,
one thread; fresh five-sample one-second `_Total` CPU readings no greater than 15% before each
timed command; 60-second and 160-MiB per-child limits; and 128 MiB / 512 entries / 1,800 seconds
outer limits. A pass requires candidate archive size at most 95% of 7-Zip and both candidate
create and extract medians no slower than 7-Zip. Any failed precondition or CPU gate stops this
registration without retrying unchanged or relaxing thresholds. Canterbury11 is still a
development corpus, not the required held-out evaluation.

Before exactly one registration, revalidate every table pin, current source manifest, no pending
lifecycle record or target process, and the read-only 290 MiB (304,087,040 B) screen reservation.
Then take five fresh external one-second `_Total` CPU readings, all at or below 15%. Use the fixed
screen parameters through `run-storage-experiment.ps1`; preserve recovery evidence and clean its
work tree only through the required Prunlet lifecycle. This preregistration does not authorize a
screen when any precondition fails. The final `STORAGE.md` SHA-256, including the pre-run
preflight outcome, must be cited in `RESEARCH_SELECTION_20261005.md` before registration.

#### Shared-preparation Canterbury11 screen pre-registration stopped at external CPU gate (2026-10-20)

The full source, input, Release CLI, 7-Zip and temporary screen-script pins matched before the
read-only preflight. All 23 existing lifecycle runs were complete; there were no target processes.
The 290 MiB reservation passed: total 1,804,697,136 / 32,212,254,720 B; external
652,025,076 / 2,147,483,648 B; Cargo 1,597,712,015 / 6,442,450,944 B; lifecycle 186,225,325 /
1,073,741,824 B; free D-drive space 536,840,531,968 B. The five fresh external one-second
`_Total` CPU readings at `2026-10-19T15:32:38.3613811Z` were `[13.4, 5.0, 19.6, 9.9, 4.4]%`;
the maximum 19.6% exceeded the fixed 15% registration threshold. Stop before registration:
no lifecycle record or screen output was created, and no 7-Zip comparison was run.

The temporary current-candidate pins used for this pre-registration attempt were the shared-
preparation source manifest `76521abb786b256dab218f1e555a216d4a82b53eeda28f06ee800e765543e172`,
Release CLI `1742b3e28e70b1a2c105ce3c0268332c712a97b0f94a3fda717809859cc81064`, worker
`a760817de5588b53657212fda0673b1b56999754717c43c66c84e87685d6e73a`, and runner
`743022bfba309f887ed647c65c51b05670a27138b7fa5197ca62b750a7778ebe`. Because the preflight
stopped before registration, the temporary CLI/source screen pins were restored to their prior
MDL-last values; the current KRS2/KRS3 shared-preparation candidate therefore cannot pass that
old screen pin set. Do not retry this same candidate/input condition unchanged or relax the CPU
gate; any future comparison requires a distinct source or evaluation condition and a fresh
preregistration. This stop provides no performance result or candidate pass/no-go decision.

### Revision-10 shared field/model preparation correctness E2E preregistration (2026-10-20)

The next code candidate shares the first KRS field scan, four normalized initial models, and their
serialized metadata between the KRS2 and KRS3 length evaluations in `PortfolioTrial`. Each coder
starts from its own model copy; adaptive updates remain candidate-local. Standalone KRS1/KRS2/KRS3
entry points remain on their prior preparation path. The bounded E2E is intended to check archive
creation, revision 1–9 compatibility, decoder safety, and CLI round-trip after this refactor. It is
not a performance measurement or a claim of byte identity against the previous executable.

| Fixed pre-build artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| 37-file `src/**/*.rs` manifest | — | `071c49fe1d3159082cade2a32d95a0b4e99603999bf28e3d0f500bd1fca0c517` |
| 42-file Rust build-input manifest, including the E2E example | — | `02350ce5494a6857762a4c649ba99f4f31391854e41dad04ac17d383c52da161` |
| `src/khc/record.rs` | 38,718 | `e65b439a10bd116997859409ffc86b018b6b4c3d5d17aa3bcb8cd6b588a995b6` |
| `src/khc/mod.rs` | 36,061 | `4613ed1e1fdcbdfe5ece704e47ecff23213e5621a4b6c0839f02712e155da7f3` |
| `examples/khc_spatial_mdl_e2e.rs` | 22,744 | `9d834c3c255fe2e14b920c47fca309bb1cb8d4e517b19ffc4221ede6faffd07c` |
| `spatial-mdl-e2e.ps1` | 11,596 | `099153c0493f6e8d1736f52cebdbf044c50baf64f0310c55f0bcdb0ab0177b8b` |
| `run-serial-cargo.ps1` / `run-storage-experiment.ps1` | 9,859 / 35,600 | `053532f8fa0266b23a6dcc02e60bfb54e94d5d58d874a71692df51dec16a158f` / `825fb8ca8425779d0bed2d0dc7001889d052444571f05a4c2573338e03faf980` |
| `storage-lifecycle.psm1` / `disk-budget.ps1` | 74,194 / 2,004 | `9686b6b258b4fc7b64e538dda7d32a0c3a355dbfa3ce12daa801395e51f942a0` / `506e4c68dc05734bc1a0c02bac6f81d4677e0bcffd9b9fa2b7bd67d53319bdcd` |
| `Cargo.toml` / `Cargo.lock` | 1,414 / 30,555 | `3b47e50b8e543a5af82617bee4d4bd48ec20fc795a333ba50cbc9e439e0c2fac` / `d8dab69b03805b559440c186ed04c2d0d0ee57eba922306cfa6827bf79985554` |
| pinned recovery ZIP (`input/ptt5`: 513,216 B) | 769,634 | `882e7108870c3de5d20de6e87ffc89f390c5d34630930aef73baed9171557f75` |

Before build, recheck these pins, process state, and the read-only Cargo storage budget. Run
`rustfmt --check --edition 2024` on `record.rs`, `mod.rs`, and the E2E example; build only the
Release CLI and E2E example through `run-serial-cargo.ps1` with `TransientMiB=256` and locked,
offline Cargo arguments `build --locked --offline --release --target x86_64-pc-windows-msvc --bin
unlhare-cli --example khc_spatial_mdl_e2e`. Target, TEMP/TMP, and intermediate output stay under
`<作業フォルダー>\UnLhaRe\goal-restore-20261019`. Pin both new executable hashes and the final
`STORAGE.md` hash in the research selection before exactly one registered run through
`run-storage-experiment.ps1` at 8 MiB / 96 entries / 300 seconds, with a 240-second child timeout
and the pinned recovery ZIP. If build, registration, or E2E fails, preserve evidence and do not
repeat this exact condition unchanged. Any result is correctness/compatibility evidence only;
candidate speed, 7-Zip superiority, holdout success, and GOAL completion remain unproven.

#### Materialized Release artifacts and pre-E2E storage check (2026-10-20)

The pinned 42-file build-input manifest remained unchanged. The serial Release build completed
successfully through `run-serial-cargo.ps1` (`Finished` in 43.63 seconds; wrapper exit 0). Its
sampled target usage started at 445,039,955 B, peaked at 451,658,735 B, ended at 445,090,471 B,
and used no deletions.

| Release artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| `unlhare-cli.exe` (`unlhare 1.0.4`) | 2,572,288 | `ba314a942cf5ca17ca4106464b0e753d950ff45a2ff1b493fb83cc54f70d5076` |
| `khc_spatial_mdl_e2e.exe` | 1,661,952 | `bc0396f96797110226bdd07e897bab50cbd2532f90f00a733d09cbb3401247f4` |

The post-build read-only budget check passed before E2E registration: total 1,804,747,652 /
32,212,254,720 B; Cargo 1,597,762,531 / 6,442,450,944 B; lifecycle 186,225,325 /
1,073,741,824 B; external 652,075,592 / 2,147,483,648 B; Cargo reservation 0; D-drive free
space 536,153,169,920 B. No Cargo, rustc, CLI, E2E, 7-Zip, or task-root process remained. The
pre-existing external `VCTIP.EXE` PID 41576 remained at the Visual Studio toolchain path and was
left untouched. The current `STORAGE.md` hash and the executable pins must be cited in the research
selection before registration.

#### Completed KRS2/KRS3 shared field/model preparation correctness E2E and cleanup (2026-10-20)

The single registered revision-10 E2E, run `abb76bfa2b254424be836b8c259561f6`, completed with all
34 child checks matching their expected results: 14 successful commands and 20 intentional
no-replace/invalid-archive rejections. The API path created revision 10 with 8 frames, exercised
the five allowed frame-family groupings, rejected 9 malformed archives, read revisions 1–9, and
checked the memory-reservation guard. The CLI path created/listed/tested/extracted a two-file
archive totaling 513,225 B; `ptt5` was restored byte-for-byte. This is correctness and compatibility
evidence only, not a speed, memory, 7-Zip, holdout, or byte-identity result.

The run evidence is retained under
`<作業フォルダー>\TaskArtifacts\UnLhaRe\goal-restore-20261019\storage-lifecycle\runs\abb76bfa2b254424be836b8c259561f6`.

| Preserved result evidence | Bytes | SHA-256 |
| --- | ---: | --- |
| `spatial-mdl-e2e.json` in the recovery ZIP | 7,162 | `59cd3b5aec1fdfc55a38a876ffb20cff6eef0d6a13487a0c428c2bdbc12f06f5` |
| revision-10 CLI archive | 40,051 | `1ac4122f904fdc95420a63317261705e16d6bfd3b4299880208890c26cc602aa` |
| `recovery.zip` | 746,804 | `b0a78a2ac887a2aeb0e1317db2032dbd6912d4691e4afbe4688e29766be51ed7` |
| `recovery.json` | 21,644 | `c8d2ae80418b153eb63b8b802ac88193e75cc47ee2ea6c4ef895f3cdd158b225` |
| `complete.json` | 1,592 | `2f7a1180003c1e9b592a4c74c39489173c58d40c230cda24f90917f55d3471a7` |
| `cleanup/delete-preview.json` | 18,943 | `49c82d2c1f071a2a4c5830acd6ea43e55d6e08882e791336838594a64c109ff6` |
| `cleanup/delete-result.json` | 29,259 | `1e163274fe04974f0d4b9997a93f58788287dd517be372ec356ceb2a15382a24` |
| `cleanup/purge-preview.json` | 29,660 | `3e44f46ee534269e2e0a03c170bbbdd64587f683fc720612ab3d25f277fca4a1` |
| `cleanup/purge-result.json` | 29,297 | `45ad1d200c9cbf511582ad0e77e9fdcf44ee9caec33351179555a310c740b659` |

The captured work tree was 5,453,097 B (74 files and 15 directories including the root, 89 entries).
An initial direct Prunlet delete/purge used operation `ccd4fe2efdf341ff8176069d04879bea`; its
stdout was not redirected to the lifecycle receipt paths, so it could not close the pending ledger
run. The hash-verified recovery ZIP/manifest were retained, the exact tree was re-materialized at
the same temporary path, and only the Prunlet cleanup stages were repeated—no build or E2E was
rerun. The receipt-backed final cleanup operation `7897d2c69b034403bf5d1ac7e412d669` passed each
stage: delete preview 89 `would_delete`, delete result 89 `deleted`, purge preview 74 `would_purge`
plus 15 `not_backed_up` directories, and purge result 74 files / 5,453,097 B purged with zero
warnings. The lifecycle finalizer recorded `complete.json` with `BeforeBytes=5,453,097` and
`AfterBytes=0`; all 24 lifecycle runs are complete, the work root is absent, and no target process
remains. Both Prunlet operations have zero retained backup files; their metadata is Prunlet-managed.
The finalizer's built-in storage-budget assertion passed. A standalone post-cleanup
`disk-budget.ps1` invocation was not available because that entry point requires
`run-storage-experiment.ps1`.

### Revision-10 PortfolioTrial scheduled-length screen pre-registration (2026-10-20)

The distinct candidate removes outer scheduled-frame assembly, byte copying, and outer CRC work
from `scheduled_lengths`, which consumes candidate sizes only. The actual `encode_scheduled`
output path still assembles and checksums the frame. Strict `frame.len() + schedule.len()` fallback
comparison, candidate-local model state, error classification, and the conservative 64 MiB gate
are unchanged. This is an encoding-work optimization hypothesis, not yet a measured speed result.

| Preregistered input | Bytes | SHA-256 |
| --- | ---: | --- |
| Full 37-file `src/**/*.rs` manifest | — | `a76be523eda227c4518e06e92fcb5ee02da2d68bb08aec4e559d19e908f3fa31` |
| 27-file `src/khc` Rust manifest | — | `061429af87ab3969ab245b8b8fae1a8aa025e275a8395f884ae68590ca328025` |
| `src/khc/record.rs` | 39,165 | `46e2a1ffe7809abd796c1d07ddfba98da396838b754b050b68f76ba943f3b68e` |
| Release `unlhare-cli.exe` (`unlhare 1.0.4`) | 2,572,800 | `3e2dda254e25c6260f6762155b82147ddea3c7d2a1fd843050bcbe2bf567edaa` |
| `portfolio-7zip-product-screen.ps1` | — | `1d930f3532cb18397754de40c07b97f866f8289665ca6d6cb087af3276cf21cf` |
| `run-storage-experiment.ps1` | — | `4bf394fdbba8eec9e6d7a9c998012358e807e749f430fafb62ad6e7a904bdaeb` |
| `run-serial-cargo.ps1` | 9,859 | `053532f8fa0266b23a6dcc02e60bfb54e94d5d58d874a71692df51dec16a158f` |
| `storage-lifecycle.psm1` / `disk-budget.ps1` | 74,194 / 2,004 | `9686b6b258b4fc7b64e538dda7d32a0c3a355dbfa3ce12daa801395e51f942a0` / `506e4c68dc05734bc1a0c02bac6f81d4677e0bcffd9b9fa2b7bd67d53319bdcd` |
| `Cargo.toml` / `Cargo.lock` | 1,414 / 30,555 | `3b47e50b8e543a5af82617bee4d4bd48ec20fc795a333ba50cbc9e439e0c2fac` / `d8dab69b03805b559440c186ed04c2d0d0ee57eba922306cfa6827bf79985554` |
| Canterbury11 recovery ZIP (`input/ptt5`: 513,216 B) | 8,765,120 | `b74644fac5f89251b15a68db6b2a3bce1bd508c12f0f685a61cd5c96ae1540bb` |
| Canterbury11 11-file source manifest | — | `bb63b0d70713c9aefa681347eaf99fb891d59f45923e009ad0deadc9ec9fc438` |
| 7-Zip 26.04 `7z.exe` | 577,536 | `95fff19b73eff77c87c0d7bd32822e43fb90dd2932459f962eb532d8dfb6ba53` |

The Release CLI was rebuilt with locked/offline Cargo through `run-serial-cargo.ps1` (`Finished`
31.73 s; wrapper exit 0). The task Cargo target grew from 445,090,471 B to a sampled peak of
462,137,441 B and ended at 455,978,490 B; there were no deletions. `rustfmt --check --edition 2024
src/khc/record.rs` passed. The read-only 290 MiB reservation passed: total 1,816,537,813 /
32,212,254,720 B; external 663,865,753 / 2,147,483,648 B; Cargo 1,608,650,550 /
6,442,450,944 B; lifecycle 187,127,467 / 1,073,741,824 B; the immediately repeated pre-registration
check still passed with D-drive free space 533,440,360,448 B. All 24 lifecycle runs were complete,
with no target process; the D task root
had no reparse point.

An initial set of five fresh external one-second `_Total` CPU samples, taken before the first
registration invocation, was `[5, 1, 0, 1, 0]%` from 2026-10-19T16:11:54.7501119Z through
2026-10-19T16:11:59.8881628Z; all met the fixed 15% gate. The exact source-manifest algorithm,
corrected pins, and subsequent CPU-gate stop are recorded below. Register exactly one Canterbury11
development screen through `run-storage-experiment.ps1`
with 128 MiB / 512 entries / 1,800 seconds outer caps; 60-second / 160-MiB child limits; one
warmup plus nine alternating paired rounds; and 7-Zip 26.04 solid LZMA2 level 9, 64 MiB
dictionary, one thread. Every timed command has its own five-sample CPU gate. Keep the fixed pass
criteria: candidate archive at most 95% of 7-Zip and candidate create/extract medians no slower
than 7-Zip, with deterministic output and exact restoration. A gate failure stops the run; do not
retry this unchanged source/input condition or loosen thresholds. Canterbury11 is development
data only; this screen cannot establish held-out superiority or complete the GOAL. No screen run
was registered, so there is no performance result or candidate decision.

The first wrapper invocation stopped before run registration at its full-source-manifest check:
the provisional `cb969…` hash had been calculated with culture-sensitive sorting rather than the
required ordinal ordering. Recalculation with the exact runner algorithm produced the 37-file
manifest `a76be523eda227c4518e06e92fcb5ee02da2d68bb08aec4e559d19e908f3fa31`; the screen/runner
pins above were corrected, with no code, input, acceptance-criteria, or format change. That
invocation created no run record or work tree and ran no comparison command. After correction,
the fresh pre-registration CPU gate stopped at its second sample: 12% at
`2026-10-19T16:15:32.5977653Z`, then 58% at `2026-10-19T16:15:33.8926897Z`. The 58% value exceeds
the fixed 15% limit. No Canterbury11 run was registered; all 24 lifecycle runs remained complete,
and no target process, 7-Zip result, or candidate pass/no-go decision was produced. Do not retry
this unchanged source/input condition or alter the fixed threshold.

### Revision-10 scheduled-length candidate correctness E2E preregistration (2026-10-20)

The scheduled-length candidate reuses each encoded inner record's length and skips only the
discarded scheduled outer-frame assembly/copy/CRC in `scheduled_lengths`. Actual archive encoding
still assembles the scheduled frame. The strict size comparison, fallback path, candidate-local
models, and conservative 64 MiB memory gate remain unchanged. This is a correctness/byte-identity
check, not a speed or resource-use result.

| Pinned input or implementation | Bytes | SHA-256 |
| --- | ---: | --- |
| Full 37-file `src/**/*.rs` manifest (ordinal path order) | — | `a76be523eda227c4518e06e92fcb5ee02da2d68bb08aec4e559d19e908f3fa31` |
| 27-file `src/khc` Rust manifest | — | `061429af87ab3969ab245b8b8fae1a8aa025e275a8395f884ae68590ca328025` |
| `src/khc/record.rs` | 39,165 | `46e2a1ffe7809abd796c1d07ddfba98da396838b754b050b68f76ba943f3b68e` |
| `src/khc/mod.rs` | 36,061 | `4613ed1e1fdcbdfe5ece704e47ecff23213e5621a4b6c0839f02712e155da7f3` |
| `examples/khc_spatial_mdl_e2e.rs` | 22,744 | `9d834c3c255fe2e14b920c47fca309bb1cb8d4e517b19ffc4221ede6faffd07c` |
| `spatial-mdl-e2e.ps1` / `run-storage-experiment.ps1` | 11,596 / 35,607 | `099153c0493f6e8d1736f52cebdbf044c50baf64f0310c55f0bcdb0ab0177b8b` / `4bf394fdbba8eec9e6d7a9c998012358e807e749f430fafb62ad6e7a904bdaeb` |
| `run-serial-cargo.ps1` | 9,859 | `053532f8fa0266b23a6dcc02e60bfb54e94d5d58d874a71692df51dec16a158f` |
| `storage-lifecycle.psm1` / `disk-budget.ps1` | 74,194 / 2,004 | `9686b6b258b4fc7b64e538dda7d32a0c3a355dbfa3ce12daa801395e51f942a0` / `506e4c68dc05734bc1a0c02bac6f81d4677e0bcffd9b9fa2b7bd67d53319bdcd` |
| `Cargo.toml` / `Cargo.lock` | 1,414 / 30,555 | `3b47e50b8e543a5af82617bee4d4bd48ec20fc795a333ba50cbc9e439e0c2fac` / `d8dab69b03805b559440c186ed04c2d0d0ee57eba922306cfa6827bf79985554` |
| Current Release `unlhare-cli.exe` | 2,572,800 | `0b81fc135a010d57bd8bf42ef46868a60b55ae1c7bdc5288e0886b7207e01719` |
| Current `khc_spatial_mdl_e2e.exe` | 1,661,952 | `d3496cbd81b384d833d1671350dd0c3cd101eb1f11dfaecdd4a897d6c003c2ee` |
| Fixed recovery ZIP (`input/ptt5`: 513,216 B) | 769,634 | `882e7108870c3de5d20de6e87ffc89f390c5d34630930aef73baed9171557f75` |
| Prior shared-preparation E2E CLI archive, from run `abb76bfa2b254424be836b8c259561f6` | 40,051 | `1ac4122f904fdc95420a63317261705e16d6bfd3b4299880208890c26cc602aa` |

The current Release CLI and E2E example were built after the scheduled-length source change with
locked/offline Cargo through `run-serial-cargo.ps1` (`Finished` 48.46 s; wrapper 49.21 s; task
target 455,978,490 B at start, sampled peak 462,584,760 B, 455,978,927 B at end; no deletions).
The read-only 8 MiB / 96-entry reservation passed before registration: total 1,816,538,250 /
32,212,254,720 B; external 663,866,190 / 2,147,483,648 B; Cargo 1,608,650,987 /
6,442,450,944 B; lifecycle 187,127,467 / 1,073,741,824 B; reserved 25,165,824 B; D-drive free
space 532,721,827,840 B. All 24 lifecycle records were complete, no target process remained, and
the task-root ancestor chain had no reparse points.

Run exactly one `spatial-mdl-e2e.ps1` registration through `run-storage-experiment.ps1` with the
fixed recovery ZIP, current executable pins, 8 MiB / 96 entries / 300 seconds outer limits, and
240-second child timeout. In addition to the finite revision-10 safety/compatibility/round-trip
checks, compare the resulting `cli_archive_sha256` to the pinned prior archive hash above. A match
establishes byte identity for this fixed input only; any outcome is not a performance, 7-Zip, or
holdout result. On registration or E2E failure, retain the recovery evidence and do not repeat this
unchanged source/input condition. The Canterbury11 CPU-gate stop above remains closed and must not
be retried or relaxed.

#### Completed scheduled-length candidate correctness E2E and cleanup (2026-10-20)

The single registered run `f66bb7133a5e46888d54003e3b594ff4` exited successfully. All 34 child
checks had their expected results (14 successful commands and 20 intentional invalid/no-replace
rejections). The API path created revision 10 with eight frames, rejected nine malformed archives,
read revisions 1–9, and exercised the memory-reservation guard. The CLI created, listed, tested, and
extracted a two-file archive totaling 513,225 B. Both restored-file hashes matched their inputs:
`ptt5.bin` `0ec3a75089bb52342813496b17e51377bc9eba3cb519a444d67025354841d650`, and `short.bin`
`073f8a6663fc49fd74e1e6dfd4d18d0bffb6e9a2af848e7adfbd4a567fbf732c`.

The preregistered full-archive hash comparison did not match: the previous 40,051 B archive was
`1ac4122f904fdc95420a63317261705e16d6bfd3b4299880208890c26cc602aa`; this run's 40,051 B archive
was `f4fbde7977bf8e1f389b758812b990d2fa0ed56715f8a4fa0861bc88e64cb55e`. Inspection found exactly
12 differing bytes: header checksum bytes 24–31 and the lower two bytes of each serialized mtime at
44–45 and 72–73. The two files' recorded mtimes differed between runs (`1792424852` / `1792424853`
versus `1792427259` / `1792427260` seconds). The 32 B header plus the two manifest records (57 B)
place the data suffix at offset 89; all 39,962 suffix bytes were identical, SHA-256
`5f66e0e3552647ce66ce6020dca6c1abae889e9bfcd3ef5b94669d5fb4364977`. Thus this fixed-input run
supports byte-identical encoded data after the timestamped manifest, but not byte-identical full
archives. It provides no speed, memory, 7-Zip, holdout, or GOAL-completion evidence.

The full result and lifecycle evidence are retained under
`<作業フォルダー>\TaskArtifacts\UnLhaRe\goal-restore-20261019\storage-lifecycle\runs\f66bb7133a5e46888d54003e3b594ff4`.

| Preserved artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| `spatial-mdl-e2e.json` in `recovery.zip` | 7,162 | `f4b65cf5670ad2d4f08bc6fe294ebe672cc910a8409ef60c181b35f7f2fa8986` |
| revision-10 CLI archive | 40,051 | `f4fbde7977bf8e1f389b758812b990d2fa0ed56715f8a4fa0861bc88e64cb55e` |
| `recovery.zip` | 746,804 | `e71d1d76c694ab920868182a641118946550472395d6547e261d2227fd433875` |
| `recovery.json` | 21,644 | `20feb0b9a97e67bb45cb090bc0d08b791f7c5d023ec636b601fc6a55e0abdcc1` |
| `complete.json` | 1,592 | `d5435db0d82b51ea828d428b9dac099fd3d586c42859039ce00c288d2d5e94d4` |
| `cleanup/delete-preview.json` | 18,943 | `4a2adf221646d66537a3cba7f26050f8987152cccc877ce466710256dc81f395` |
| `cleanup/delete-result.json` | 29,259 | `1e36c6456700aeeb8a935c984345f2d09bc79304302ec52a48a2890cdd09d5b8` |
| `cleanup/purge-preview.json` | 29,660 | `a6de85f2ce79dc1c9fbb3907816a0d899c13fce3b7b8be7d1d78031ecfe43a18` |
| `cleanup/purge-result.json` | 29,297 | `d75fed05d0a2427280b506306c76b0fea71e9f1587f992a757f7c200f8aa325b` |

Prunlet operation `db1d2c0f6c244d95a6a50ca46eac9c77` verified the exact 89-entry work tree,
deleted 89 entries, and purged 74 files totaling 5,453,097 B with zero warnings. The finalizer
recorded `BeforeBytes=5,453,097` and `AfterBytes=0`; all 25 lifecycle runs are complete, the work
directory is absent, and no target process remains.

### Revision-10 schedule-replay candidate correctness E2E preregistration (2026-10-20)

The candidate replays the existing schedule during KRS2/KRS3 histogram and entropy scans instead
of rebuilding and observing a 65,536-slot voter for each scheduled candidate. Copy-run boundaries,
serialized record order, decoder, fallback, and the 64 MiB memory gate are intended to remain
unchanged. This bounded E2E checks the existing revision-10 safety/compatibility and CLI
round-trip path, then compares only the encoded data suffix to the prior candidate's pinned output;
it is not a performance, memory, 7-Zip, holdout, or GOAL-completion result.

| Fixed pre-run artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| Full `src/**/*.rs` manifest (37 files, ordinal relative-path order) | — | `0f549ab7f8c675b8ef241279d8ab29f90e9c7b7e32a5bc08c7effd0dc861c404` |
| `src/khc/**/*.rs` manifest (27 files, ordinal relative-path order) | — | `15a4ec2660cd8eecf83743ce347173c971c822c0ce95e0155672c5ed19635500` |
| `src/khc/record.rs` | 42,504 | `9527239e9be4e31680273420260697b26fdddda68a7434d9e1628495d90697b6` |
| `src/khc/mod.rs` | 36,061 | `4613ed1e1fdcbdfe5ece704e47ecff23213e5621a4b6c0839f02712e155da7f3` |
| `examples/khc_spatial_mdl_e2e.rs` | 22,744 | `9d834c3c255fe2e14b920c47fca309bb1cb8d4e517b19ffc4221ede6faffd07c` |
| `Cargo.toml` / `Cargo.lock` | 1,414 / 30,555 | `3b47e50b8e543a5af82617bee4d4bd48ec20fc795a333ba50cbc9e439e0c2fac` / `d8dab69b03805b559440c186ed04c2d0d0ee57eba922306cfa6827bf79985554` |
| Release x64 MSVC `unlhare-cli.exe` | 2,575,360 | `3dd0e0503ed6ec11c90ad1ff9ee69b2e34c564f8710871ab182dd684f27b7b4b` |
| Release x64 MSVC `khc_spatial_mdl_e2e.exe` | 1,665,024 | `8e02b2bd126b058eaa1a1679456d572e736161894633f113a2be8643694b213e` |
| `spatial-mdl-e2e.ps1` / `run-storage-experiment.ps1` | 11,596 / 35,607 | `099153c0493f6e8d1736f52cebdbf044c50baf64f0310c55f0bcdb0ab0177b8b` / `4bf394fdbba8eec9e6d7a9c998012358e807e749f430fafb62ad6e7a904bdaeb` |
| `run-serial-cargo.ps1` | 9,859 | `053532f8fa0266b23a6dcc02e60bfb54e94d5d58d874a71692df51dec16a158f` |
| `storage-lifecycle.psm1` / `disk-budget.ps1` | 74,194 / 2,004 | `9686b6b258b4fc7b64e538dda7d32a0c3a355dbfa3ce12daa801395e51f942a0` / `506e4c68dc05734bc1a0c02bac6f81d4677e0bcffd9b9fa2b7bd67d53319bdcd` |
| Fixed recovery ZIP (`input/ptt5`: 513,216 B) | 769,634 | `882e7108870c3de5d20de6e87ffc89f390c5d34630930aef73baed9171557f75` |
| Prior scheduled-length CLI archive data suffix at offset 89 (39,962 B) | 39,962 | `5f66e0e3552647ce66ce6020dca6c1abae889e9bfcd3ef5b94669d5fb4364977` |

The correct-target locked/offline Release build was invoked through `run-serial-cargo.ps1`. Cargo
finished in 46.12 seconds, but the wrapper returned 1 because `VCTIP.EXE` was still in its job at
the 2-second drain check; after the child exited, one identical no-op invocation returned 0
(`Finished` 0.10 seconds). No process was killed. A prior command without the target triple also
produced host-target outputs under the same D-drive Cargo root; those files were retained because
there was no pre-run inventory to establish safe deletion. The current storage budget includes
those outputs. All future binaries for this preregistration are the explicitly pinned
`x86_64-pc-windows-msvc` files above.

Immediately before registration, the read-only budget check passed with 25,165,824 B reserved:
total 1,834,146,500 / 32,212,254,720 B; external 681,474,440 / 2,147,483,648 B; Cargo
1,625,357,095 / 6,442,450,944 B; lifecycle 188,029,609 / 1,073,741,824 B; D-drive free space
531,257,626,624 B. `Assert-KhcNoPendingStorageRuns` passed across both lifecycle roots; all 25
task lifecycle records were complete and no Cargo, rustc, KHC CLI/E2E, or 7-Zip process was
running. Register exactly one run through `run-storage-experiment.ps1` with the fixed input and
binary hashes above, outer limits 8 MiB / 96 entries / 300 seconds, and child timeout 240 seconds.
The E2E report records the full CLI archive hash; compare the extracted archive's 39,962-byte
suffix to the pinned baseline above because timestamped manifest/header bytes are not expected to
be stable. If registration or the E2E fails, preserve recovery evidence and do not repeat this
unchanged source/input condition.

The exact invocation is:

```powershell
$env:KHC_STORAGE_TASK_ID = 'goal-restore-20261019'
& 'D:\Dev\UnLhaRe\UnLhaRe\experiments\khc\run-storage-experiment.ps1' `
  -ScriptPath 'D:\Dev\UnLhaRe\UnLhaRe\experiments\khc\spatial-mdl-e2e.ps1' `
  -ScriptParameters @{
    InputRecoveryZip = '<作業フォルダー>\TaskArtifacts\UnLhaRe\storage-lifecycle\runs\8a849a3267954242bcd8424b93526176\recovery.zip'
    KhcExecutable = '<作業フォルダー>\UnLhaRe\goal-restore-20261019\cargo\x86_64-pc-windows-msvc\release\unlhare-cli.exe'
    KhcExecutableSha256 = '3dd0e0503ed6ec11c90ad1ff9ee69b2e34c564f8710871ab182dd684f27b7b4b'
    E2eExecutable = '<作業フォルダー>\UnLhaRe\goal-restore-20261019\cargo\x86_64-pc-windows-msvc\release\examples\khc_spatial_mdl_e2e.exe'
    E2eExecutableSha256 = '8e02b2bd126b058eaa1a1679456d572e736161894633f113a2be8643694b213e'
    ChildTimeoutSeconds = 240
  } `
  -MaxRunMiB 8 -MaxEntries 96 -TimeoutSeconds 300
```

#### First schedule-replay correctness E2E stopped by live directory-scan race; cleanup completed (2026-10-20)

The single registration `3e44744ddf604d959fc05b042f4694f6` used work directory
`<作業フォルダー>\UnLhaRe\goal-restore-20261019\run-8445434dc27047e68d1117e9e8c9b566`. The wrapper
returned 1 while `Get-KhcRunUsage` called `TreeCounter.Measure`: the accepted-output extraction
created a `cap_tempfile::TempDir` under `api\accepted-all-output` and published files out of that
directory. The live accounting scan tried to enumerate a GUID staging directory as it vanished
(`70e38f55-beb0-4bdf-8850-874e36033033`). The recovery snapshot contained a different transient
GUID directory plus all eight extracted accepted-output files, consistent with a scan/cleanup
race. No `spatial-mdl-e2e.json` was produced and the CLI round-trip phase was not reached. This is
an infrastructure interruption; it is neither a passing nor failing candidate correctness result.

Recovery contains the original fixed input and partial API state; the evidence remains available
for diagnosis. The work tree measured 4,049,929 B and was removed only after verifying the single
Prunlet paths-file target and all recovery hashes. Prunlet operation `08ea91fe9ef044ebaeadfe244650ce43`
deleted the 34-entry work tree, then purged 27 backed-up files totaling 4,049,929 B with zero
warnings. The run finalizer recorded `BeforeBytes=4,049,929`, `AfterBytes=0`, `State=complete`; the
recovery ZIP and manifest remain retained. The dry-run preview was preserved from the observed
pre-delete CLI result in normalized JSON form and passed the lifecycle validator.

| Preserved artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| `recovery.zip` | 381,938 | `e6a22cf830c54724c459a849dfdc5dd303831bf86b89559ec066eb082605560a` |
| `recovery.json` | 8,519 | `01a014778281a3ca7b56d2420b1adbc61cacbc041c98bc510d6670d67881f4d4` |
| `cleanup-request.json` | 9,543 | `07fa90d40aa170bb06b1e823b4f146b0ccd8b8e09b657e5d6df30335a5636093` |
| `cleanup/delete-preview.json` | 9,879 | `1ce9d11ef82f0355fff597500cb7d86ec8b69e20b4456a834aa21634c65d96c2` |
| `cleanup/delete-result.json` | 13,655 | `40d465ded5d552282e9100e71d19216da193d659cf6c6857029b8cb42b4ef4f8` |
| `cleanup/purge-preview.json` | 11,246 | `7ec37e837a411e688fe11aa3b8c7135e49602251f76a520cb74348cb582c6e6f` |
| `cleanup/purge-result.json` | 11,118 | `44a5e3657898f4197cea64f6e5a1f7265cd8ba344f44a5092573753243c475fb` |
| `complete.json` | 1,592 | `89a6f07a547cbb36cdd9c37a0c4af449b6d74575c433b6e3c211e62d9a752d00` |

#### Bounded live-scan retry and one re-registered correctness E2E (2026-10-20)

`run-storage-experiment.ps1` now retries the live tree accounting scan at most three times with a
10 ms delay, and only when the exception chain contains `DirectoryNotFoundException`. Capacity,
entry-count, path-length, and reparse-point failures remain immediate and unchanged; other I/O
errors still fail immediately. PowerShell parsing passed. The changed harness is pinned separately:

| Changed harness | Bytes | SHA-256 |
| --- | ---: | --- |
| `run-storage-experiment.ps1` with bounded scan retry | 36,311 | `4c091b2f56f952450848d048ff9aa54e523fe953a484d10be7b386683f8c5c32` |

The source manifest (`0f549ab7f8c675b8ef241279d8ab29f90e9c7b7e32a5bc08c7effd0dc861c404`), KHC
manifest (`15a4ec2660cd8eecf83743ce347173c971c822c0ce95e0155672c5ed19635500`), E2E script,
fixed recovery ZIP, and both Release binaries remain at the pins in the preceding preregistration.
The E2E command and limits are otherwise identical. This is the one authorized follow-up for the
same source/input because the first run stopped in the accounting harness before producing an E2E
result, and the runner itself is now a different hash. This second registration must use that new
runner hash. If it fails, preserve the recovery evidence and do not repeat this source/input again.
It remains a correctness check only, not a performance or holdout result.

After the runner fix, a fresh read-only pre-registration check confirmed both source manifests and
all candidate, input, E2E-script, runner, and Release-binary pins above. The runner parsed without
PowerShell errors; `Assert-KhcNoPendingStorageRuns` passed across the lifecycle roots; the 25 MiB
reservation passed `Assert-KhcStorageBudget`; the task work/Cargo roots and existing ancestors had
no reparse points; and no Cargo, rustc, CLI, E2E, or 7-Zip process was active. The budget snapshot
was total 1,834,596,265 / 32,212,254,720 B, external 681,924,205 / 2,147,483,648 B, Cargo
1,625,357,095 / 6,442,450,944 B, lifecycle 188,479,374 / 1,073,741,824 B, with 25,165,824 B
reserved and 529,909,452,800 B free on D:. The repaired runner pin is 36,311 B,
`4c091b2f56f952450848d048ff9aa54e523fe953a484d10be7b386683f8c5c32`. The one follow-up was
registered only after the selection record cited the updated pre-registration `STORAGE.md` hash
and the final pre-registration pin check passed.

#### Repaired schedule-replay correctness E2E completed and cleaned (2026-10-20)

The one authorized follow-up run `22244102afa34627b750d52fb6cf0a98` completed successfully with
the repaired runner. All 34 checks matched their expected exit codes: 14 succeeded and 20
intentional malformed-input/no-replace checks returned 1. The API produced revision 10 with eight
frames, enforced the five-family allowlist, rejected nine malformed archives, read revisions 1–9,
and exercised the memory reservation guard. The CLI created, listed, tested, and extracted a
two-file archive totaling 513,225 B; restored `ptt5.bin` and `short.bin` matched their input SHA-256
values (`0ec3a75089bb52342813496b17e51377bc9eba3cb519a444d67025354841d650` and
`073f8a6663fc49fd74e1e6dfd4d18d0bffb6e9a2af848e7adfbd4a567fbf732c`).

The CLI archive was 40,051 B, SHA-256
`0869d12e932532a1b272eccd461d54970ebac83ee572d649608de368f650c48d`. Against the preceding
scheduled-length E2E archive (`f4fbde7977bf8e1f389b758812b990d2fa0ed56715f8a4fa0861bc88e64cb55e`),
exactly 12 bytes differ at offsets 24–31, 44–45, and 72–73 (header checksum and serialized
mtimes). The 39,962-byte data suffix from offset 89 is identical, SHA-256
`5f66e0e3552647ce66ce6020dca6c1abae889e9bfcd3ef5b94669d5fb4364977`, matching the preregistered
baseline. This proves fixed-input encoded-data identity only; it is not a speed, memory, 7-Zip,
holdout, or GOAL-completion result.

| Preserved artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| `spatial-mdl-e2e.json` in `recovery.zip` | 7,162 | `3400273c6b05e0c4170b157fdb1cf9299299052fbba8ec6d48d14fd9e103340e` |
| revision-10 CLI archive in `recovery.zip` | 40,051 | `0869d12e932532a1b272eccd461d54970ebac83ee572d649608de368f650c48d` |
| `recovery.zip` | 746,804 | `2ea18aabca6a69db765b40f2a5b03f2c4cb59a5a4b9873dceef27feaf2908813` |
| `recovery.json` | 21,644 | `90b591ee649f3c0ba5398893a4fade972f7c6d89a4c95baffed52b62b1864967` |
| `cleanup-request.json` | 22,668 | `80e5f89dbdc2e349e947c20387d7b1906ed69f791fc588dcc86dc2800d07ae39` |
| `complete.json` | 1,592 | `d5336419a74d0e36519f86c0beffcc0d94bc842432d13cd8ec278fc82d012b35` |
| `cleanup/delete-preview.json` | 18,943 | `396b1830955153194004ccedb7404d7c0026f321f84501362db632f8cfcc583a` |
| `cleanup/delete-result.json` | 29,259 | `846c4472673a35305ee4e27cce39fed695ad38f9446afc2ef34b078f56d6b6cf` |
| `cleanup/purge-preview.json` | 29,660 | `a8b7996e592e7dee7ae15f936b567f51506bd14af7e32a2837f0a2c4946abec8` |
| `cleanup/purge-result.json` | 29,297 | `04e7631493cdb2a10a9cfbb1276d7d19b0f652c4ba48f377fb6370f54e2c5c35` |

Prunlet operation `78f9c305714d431495406755d0f89668` passed the staged delete-preview, delete,
purge-preview, and purge-apply validators. The registered 89-entry work tree measured 5,453,097 B;
Prunlet deleted it and purged the corresponding 74 files. Finalization recorded `BeforeBytes=5,453,097`,
`AfterBytes=0`, `State=complete`; the work path is absent and the recovery archive/manifest and
receipts remain intact. The post-cleanup read-only check passed with no pending lifecycle runs and
no target process: total 1,835,498,407 / 32,212,254,720 B, external 682,826,347 / 2,147,483,648 B,
Cargo 1,625,357,095 / 6,442,450,944 B, lifecycle 189,381,516 / 1,073,741,824 B, reserve
25,165,824 B, and D-drive free space 529,908,248,576 B.

### Schedule-replay revision-10 Canterbury11 / 7-Zip product-screen preregistration (2026-10-20)

The candidate source is the schedule-replay implementation, which reuses the prepared field
schedule during KRS2/KRS3 portfolio evaluation. This is a distinct source/binary from the prior
`scheduled_lengths` Canterbury11 screen that stopped at its fixed CPU gate; that stop remains
closed and its threshold is not being relaxed. The fixed Canterbury11 comparison below retains
the prior 7-Zip configuration, acceptance criteria, and resource ceilings. It is a development
screen only; even a pass does not establish held-out superiority or complete the GOAL.

| Fixed pre-run artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| Canterbury11 raw manifest (11 files; 2,810,784 B total) | — | `bb63b0d70713c9aefa681347eaf99fb891d59f45923e009ad0deadc9ec9fc438` |
| Canterbury11 recovery ZIP | 8,765,120 | `b74644fac5f89251b15a68db6b2a3bce1bd508c12f0f685a61cd5c96ae1540bb` |
| Full 37-file `src/**/*.rs` manifest | — | `0f549ab7f8c675b8ef241279d8ab29f90e9c7b7e32a5bc08c7effd0dc861c404` |
| 27-file `src/khc/**/*.rs` manifest | — | `15a4ec2660cd8eecf83743ce347173c971c822c0ce95e0155672c5ed19635500` |
| `src/khc/record.rs` / `src/khc/mod.rs` | 42,504 / 36,061 | `9527239e9be4e31680273420260697b26fdddda68a7434d9e1628495d90697b6` / `4613ed1e1fdcbdfe5ece704e47ecff23213e5621a4b6c0839f02712e155da7f3` |
| Release x64 MSVC `unlhare-cli.exe` | 2,575,360 | `3dd0e0503ed6ec11c90ad1ff9ee69b2e34c564f8710871ab182dd684f27b7b4b` |
| 7-Zip 26.04 `7z.exe` | 577,536 | `95fff19b73eff77c87c0d7bd32822e43fb90dd2932459f962eb532d8dfb6ba53` |
| Updated `portfolio-7zip-product-screen.ps1` | 33,153 | `15d21142816679c0e325ae1abcefa29992a989048c8e4ae4e253892de36556e9` |
| Updated `run-storage-experiment.ps1` | 36,310 | `d513872f7a36e96c6a03c24b26eb74f65377db4c9d7462e4e29cfde2e315170b` |
| `storage-lifecycle.psm1` / `disk-budget.ps1` | 74,194 / 2,004 | `9686b6b258b4fc7b64e538dda7d32a0c3a355dbfa3ce12daa801395e51f942a0` / `506e4c68dc05734bc1a0c02bac6f81d4677e0bcffd9b9fa2b7bd67d53319bdcd` |
| `Cargo.toml` / `Cargo.lock` | 1,414 / 30,555 | `3b47e50b8e543a5af82617bee4d4bd48ec20fc795a333ba50cbc9e439e0c2fac` / `d8dab69b03805b559440c186ed04c2d0d0ee57eba922306cfa6827bf79985554` |

The worker and acceptance protocol are pinned: one warmup then nine alternating paired rounds;
full KHC and `.7z` archive creation plus filesystem extraction; exact restore of all 11 files;
deterministic archive bytes across each strategy's repetitions; and verification of both archive
formats. 7-Zip uses `-t7z -mx=9 -m0=lzma2:d=64m -mmt=1 -ms=on -mqs=off -mtm=off -mtc=off
-mta=off`; child timeout and memory ceilings remain 60 seconds and 160 MiB. The fixed pass requires
the complete KHC archive to be at most 95% of the 7-Zip archive and both KHC create and extract
median wall times to be no slower than 7-Zip. The registered outer cap is 128 MiB / 512 entries /
1,800 seconds. Before each timed command, the worker requires five one-second `_Total` CPU samples
at or below 15%, with no wait-and-retry after a gate failure.

The pin-only changes update the worker's source manifest and candidate CLI hashes, then update the
runner's matching worker/CLI/source-manifest pins. No threshold, 7-Zip option, input, or output
criteria changed. Both PowerShell files parsed without errors. Before taking the external CPU gate,
the read-only preflight passed the 290 MiB (304,087,040 B) reservation, `Assert-KhcNoPendingStorageRuns`,
plain task/Cargo path checks, and a zero target-process check. The measured budget was total
1,835,498,407 / 32,212,254,720 B, external 682,826,347 / 2,147,483,648 B, Cargo
1,625,357,095 / 6,442,450,944 B, lifecycle 189,381,516 / 1,073,741,824 B, with 529,885,425,664 B
free on D:. The single fresh external `_Total` CPU gate passed at
`2026-10-19T17:21:23.9951291Z`–`2026-10-19T17:21:29.1408634Z` with readings `[3, 6, 2, 0, 0]%`,
all at or below the fixed 15% threshold. This authorizes only one registration; any later worker
CPU-gate failure still stops without retrying this source/input condition. The exact registration
parameters are:

```powershell
$env:KHC_STORAGE_TASK_ID = 'goal-restore-20261019'
$screenParameters = @{
    KhcExecutable = '<作業フォルダー>\UnLhaRe\goal-restore-20261019\cargo\x86_64-pc-windows-msvc\release\unlhare-cli.exe'
    SevenZipPath = 'C:\Program Files\7-Zip\7z.exe'
    InputRecoveryZip = '<作業フォルダー>\TaskArtifacts\UnLhaRe\storage-lifecycle\runs\5e93ed1e99ca4f5ab29d490db421e50b\recovery.zip'
}
& .\experiments\khc\run-storage-experiment.ps1 `
    -ScriptPath .\experiments\khc\portfolio-7zip-product-screen.ps1 `
    -ScriptParameters $screenParameters -MaxRunMiB 128 -MaxEntries 512 -TimeoutSeconds 1800
```

### Aozora development-only 7-Zip screen preregistration (2026-10-20)

The immutable marker is
`<作業フォルダー>\TaskArtifacts\UnLhaRe\goal-restore-20261019\aozora-dev-20261020\campaign-start.json`
(2,333 B, SHA-256 `1c2e4fb5f96a420a769ac255751deec64008e211968194d7557f1285a1adbaff`), campaign
`f3d12bcb02bb4e3c97f6417062d6d5a7`, fixed to 2026-10-19 19:50–20:20 UTC. The lifecycle validator
accepted the marker, all pins, and input profile before its start time. There are not yet any
Aozora run registrations, builds for this profile, timed commands, cleanup operations, or
performance results. The prior e-Gov campaign remains stopped before registration and must not be
retried. This is a distinct development-only input condition, not an independent holdout or
evidence of 7-Zip superiority.

The fixed input package is
`<作業フォルダー>\TaskArtifacts\UnLhaRe\goal-restore-20261019\aozora-dev-20261020\input.zip` (222,247 B,
SHA-256 `9772d6af224028a70c2d50af8f64faebf03de9a487a08fee566de4c1128cb0b6`). Its members are
`input/bocchan.txt` (209,990 B, SHA-256
`8b1087162da44dbf54705c15f5ba62c7c07db86bb6f38caacd4f5beb62e4618b`) and `input/lemon.txt`
(12,019 B, SHA-256 `979e3e94b2537ef922851023bef4c32530ba4b7eef2e3c15bf66c80a495a5512`). Package
manifest: `e7ba78c324e97d677f1e1c9aa0371234666a643227fccfbab4c2d70db1204307`; original candidate
manifest: `caa078a5053669dfd0fb90ebe9d3941b69a76a36600dec2579495f0de58c516d`; basename-sorted
`path<TAB>bytes<TAB>SHA-256` file-set digest (UTF-8, no BOM, LF, no final LF):
`4d9ded91fe0a2e7657cce870f7fd39a4c83c8b7fe5e26f7230ebd8e53c1d2ea6`. The two works form one
Aozora source family and are for development/tuning only; rights and attribution caveats remain in
`RESEARCH_SELECTION_20261005.md`. No holdout data is included.

The immutable profile is `AozoraDevelopment20261020`, task `goal-restore-20261019`. It fixes 20
serial one-sample runs: rounds 0–9, one `portfolio-trial` revision-10 and one 7-Zip 26.04 sample
per round, alternating first strategy by parity; round 0 is warmup and rounds 1–9 are measured.
Per-run caps are 32 MiB / 512 entries / 300 seconds; child caps are 160 MiB / 60 seconds; the
campaign wall cap is 1,800 seconds. A fresh five-sample external `_Total` CPU gate at or below 15%
is required before the first registration and each timed command. The full Prunlet lifecycle must
complete before the next registration. No failed gate, sample, cleanup, or deadline is retried.
The requested 7-Zip options remain solid LZMA2 level 9, `-m0=lzma2:d=64m`, create `-mmt=1`,
extract `-mmt=4`, with timestamps/attributes disabled and solid mode enabled. Worker and Aozora
aggregator agree on a unique effective dictionary value `0 < bytes <= 64 MiB`; the e-Gov
aggregator retains its exact-64-MiB gate. The actual effective value has not been measured.

A pre-registration read-only preflight passed: no pending lifecycle runs, no target processes,
plain work/TaskArtifacts/corpus path chains, exact input ZIP/profile members and source manifest,
and all source/tool/script/Cargo/disk-budget pins. With a 33,554,432 B reservation, observed usage
was total 1,837,940,822 / 32,212,254,720 B, external 685,268,762 / 2,147,483,648 B, Cargo
1,625,357,095 / 6,442,450,944 B, lifecycle 190,572,106 / 1,073,741,824 B, and D: free
524,488,093,696 B. Repeat that preflight and take the campaign's fresh five-sample external CPU
gate at or after 19:50 UTC before the first registration; any failure stops this fixed campaign.

| Pinned artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| `portfolio-7zip-product-screen.ps1` | 35,069 | `4a0042a84eeca12e5f7590f1b8f06b5cbfb3eee67128c4126a7a9d292b93e8b5` |
| `run-storage-experiment.ps1` | 40,667 | `4653d3f765da0c8ced72177c0f190d3bc2771a9e132b3aee176145b08f79ecfe` |
| `storage-lifecycle.psm1` | 94,868 | `18aa24991b267c7004f6da7cd163fb9e60f76c5ac6a273d276d94cd914f7f114` |
| `aggregate-portfolio-7zip-product-screen.ps1` | 42,853 | `c67c91be75c412e7f96a58d6caeb0691a277e0e5335711a5fa7a8fdca26471c7` |
| `disk-budget.ps1` | — | `506e4c68dc05734bc1a0c02bac6f81d4677e0bcffd9b9fa2b7bd67d53319bdcd` |
| `Cargo.toml` / `Cargo.lock` | 1,414 / 30,555 | `3b47e50b8e543a5af82617bee4d4bd48ec20fc795a333ba50cbc9e439e0c2fac` / `d8dab69b03805b559440c186ed04c2d0d0ee57eba922306cfa6827bf79985554` |
| Rust source manifest / KHC manifest | 37 files / 27 files | `0f549ab7f8c675b8ef241279d8ab29f90e9c7b7e32a5bc08c7effd0dc861c404` / `15a4ec2660cd8eecf83743ce347173c971c822c0ce95e0155672c5ed19635500` |
| Release x64 MSVC `unlhare-cli.exe` | 2,575,360 | `3dd0e0503ed6ec11c90ad1ff9ee69b2e34c564f8710871ab182dd684f27b7b4b` |
| 7-Zip 26.04 `7z.exe` | — | `95fff19b73eff77c87c0d7bd32822e43fb90dd2932459f962eb532d8dfb6ba53` |
| Marker `campaign-start.json` | 2,333 | `1c2e4fb5f96a420a769ac255751deec64008e211968194d7557f1285a1adbaff` |

The worker command for each `(round,strategy)` pair is:

```powershell
$env:KHC_STORAGE_TASK_ID = 'goal-restore-20261019'
$campaignSha = '1c2e4fb5f96a420a769ac255751deec64008e211968194d7557f1285a1adbaff'
$inputZip = '<作業フォルダー>\TaskArtifacts\UnLhaRe\goal-restore-20261019\aozora-dev-20261020\input.zip'
$khc = '<作業フォルダー>\UnLhaRe\goal-restore-20261019\cargo\x86_64-pc-windows-msvc\release\unlhare-cli.exe'
$seven = 'C:\Program Files\7-Zip\7z.exe'
$parameters = @{
    CorpusProfile = 'AozoraDevelopment20261020'; Round = $round; Strategy = $strategy
    InputRecoveryZip = $inputZip; KhcExecutable = $khc; SevenZipPath = $seven
    CampaignManifestSha256 = $campaignSha
}
& .\experiments\khc\run-storage-experiment.ps1 `
    -ScriptPath .\experiments\khc\portfolio-7zip-product-screen.ps1 `
    -ScriptParameters $parameters -MaxRunMiB 32 -MaxEntries 512 -TimeoutSeconds 300
```

Do not submit the next pair until the current run has completed the full Prunlet cleanup flow and
all recovery/report/receipt hashes validate. Aggregate only after the fixed deadline with the exact
20 run IDs, actual finish time, and recorded initial-gate timestamps/readings:

```powershell
& .\experiments\khc\aggregate-portfolio-7zip-product-screen.ps1 `
    -RunIds $runIds -CampaignStartedUtc ([DateTimeOffset]::Parse('2026-10-19T19:50:00Z')) `
    -CampaignFinishedUtc $campaignFinishedUtc -StartGateStartedUtc $startGateStartedUtc `
    -StartGateFinishedUtc $startGateFinishedUtc -StartGateCpuPercent $startGateCpuPercent `
    -CorpusProfile AozoraDevelopment20261020 -CampaignManifestSha256 $campaignSha
```

The lifecycle validator accepted the immutable marker before its window opened in the matching
`goal-restore-20261019` execution context; an explicit mismatched task ID and an out-of-window
`-RequireOpenWindow` validation were both rejected. The four scripts all parse cleanly; independent
review verified the execution-task binding and matching worker / aggregator dictionary range. The
prior target x64 MSVC build was
already materialized by `run-serial-cargo.ps1`; no independent build receipt was found. Acceptance
remains deterministic archives, format validation, exact restoration, candidate size at most 95% of
7-Zip, and no-slower revision-10 create/extract medians. Even a pass is development-only and cannot establish
independent-holdout superiority or complete the GOAL.

#### Aozora fixed campaign stopped before registration at external CPU gate (2026-10-20)

The immutable 19:50–20:20 UTC campaign was stopped before its first registration. The fresh
external `_Total` CPU gate began at `2026-10-19T19:50:24.4819087Z`; the five captured readings were
29%, 18%, 19%, 19%, and 19%, all above the fixed 15% ceiling. The collector continued for the
remaining four readings after the first 29% exceeded the limit; this is a recorded gate-procedure
deviation. No candidate or 7-Zip process was started, no lifecycle run directory was created in
the campaign window, and there are zero registrations or timed commands. The lifecycle pending-run
check passed and no cleanup was required. This source/input condition and fixed window are closed;
do not retry, rebase, or relax the threshold. This is not a codec no-go or a performance result.

The retained stop record is
`<作業フォルダー>\TaskArtifacts\UnLhaRe\goal-restore-20261019\aozora-dev-20261020\pre-registration-stop.json`
(2,298 B, SHA-256 `4409ee3a6d5656293bcba320bdb341d077cb4230343ebab32da6ea3bda6c0821`). Its preflight
snapshot, marker/tool/source/input pins, exact UTC readings, run-directory check, and procedure
deviation are machine-readable there. The immutable campaign-start marker remains preserved.

#### JMA Tokyo daily independent holdout profile integration (2026-10-20)

The fixed input is the single unmodified Tokyo daily weather CSV (2010-01-01 through 2025-12-31),
stored at `<作業フォルダー>\TaskArtifacts\UnLhaRe\goal-restore-20261019\jma-holdout-20261020\` with
an uncompressed one-member `input.zip`. The profile requires the recorded ZIP path, length, SHA-256,
member name/length/SHA-256, and file-set manifest. It is `holdout-only`; `development_only`,
`training_allowed`, and `tuning_allowed` are false. Preserve the JMA attribution and PDL 1.0 terms
recorded in `RESEARCH_SELECTION_20261005.md`. The 169,060-byte payload remains sealed and has not
been opened, parsed, transformed, compressed, or measured.

Four PowerShell paths now support this separate immutable marker: worker
`portfolio-7zip-product-screen.ps1` (35,886 B, SHA-256
`d55b06a5daa65ea149f3ec9c8807b6cb451e8eb8229cb132603a0c468489cbc7`), runner
`run-storage-experiment.ps1` (40,894 B, `b560c3245961b03308300fbebc5f3cca3b2dba3db177c6ee59083b1ec9054ae5`),
lifecycle `storage-lifecycle.psm1` (99,912 B,
`8896cc2f6a7eb543acbe9454655b3228b79dfcb61dbb35a179ffcc6a9eaa9495`), and aggregator
`aggregate-portfolio-7zip-product-screen.ps1` (44,538 B,
`56973bd1a2703e88bba299aadae3ff8423b2fe79d15da09727f442cd44555ba0`). The candidate Rust source
manifest is `0f549ab7f8c675b8ef241279d8ab29f90e9c7b7e32a5bc08c7effd0dc861c404`; the pinned Release
CLI is 2,575,360 B, SHA-256 `3dd0e0503ed6ec11c90ad1ff9ee69b2e34c564f8710871ab182dd684f27b7b4b`; 7-Zip
26.04 is `C:\Program Files\7-Zip\7z.exe`, SHA-256
`95fff19b73eff77c87c0d7bd32822e43fb90dd2932459f962eb532d8dfb6ba53`.

The fixed 7-Zip creation settings are solid LZMA2 level 9, `d=64m`, one thread, timestamps off;
extraction uses four threads. The marker must state
`maximum_effective_dictionary_bytes=67108864`; each actual unique LZMA2 dictionary must be positive
and at most 64 MiB. For this one-member input, the worker records either actual `Solid` flag but
still requires one block and the pinned `-ms=on` command; multi-member profiles still require
`Solid=+`. Acceptance is unchanged: deterministic archives, exact restoration, candidate size at
most 95% of 7-Zip, and no-slower create/extract medians. Runs remain capped at 20 total
(one warmup plus nine measured pairs), 32 MiB / 512 entries per run, 300 seconds per run,
160 MiB per process, 1,800 seconds total, with the 15% CPU gate before registration and each timed
command.

No JMA `campaign-start.json` exists; no JMA registration, candidate/7-Zip process, timed command,
or aggregate has run. Before creating the marker, repeat the full storage/lifecycle/input/tool
preflight and obtain a fresh five-sample external `_Total` CPU gate at or below 15%. Then create a
new 30-minute UTC window and marker only when ready to register. A gate failure closes this exact
holdout condition; do not rebase its data, time window, candidate, or threshold. This independent
screen is not by itself a representative-data result or GOAL completion.

#### JMA independent holdout stopped before registration at the CPU gate (2026-10-20)

The full preflight passed: no pending lifecycle runs or active candidate/7-Zip processes, fixed
Rust source manifest and all script/tool/input pins matched, and the 290 MiB reserve was within
the storage caps. The fresh external _Total CPU gate failed on its first sample at 37.49% against
the fixed 15% ceiling; collection stopped immediately, so the remaining four samples were not
taken. No campaign marker or lifecycle registration was created; neither the candidate nor 7-Zip
was invoked, and there is no timing, size comparison, aggregate, or cleanup to perform.

This closes the exact JMA source/input/candidate/threshold condition. Do not create a replacement
time window or retry this condition. This is an environmental pre-registration stop, not a codec
no-go. The machine-readable pre-registration record is
`<作業フォルダー>\TaskArtifacts\UnLhaRe\goal-restore-20261019\jma-holdout-20261020\pre-registration-stop.json`
(2,910 B, SHA-256 `00848fe5204696ad6eff1db160a6a5fbfbe6958977f8b180878296ac68e79e34`).

#### Tokyo resident-register independent holdout profile integration (2026-10-20)

The separate profile `TokyoResidentRegister202101Holdout20261020` is fixed to the January 2021
Tokyo resident-register Table 5 CSV. The source member is 295,022 B, SHA-256
`24f90c92c90500bef3e7e2170691a7bcc4fa0f22ecfe8f20cb9e1586e49af1a8`; its campaign wrapper is
295,202 B, SHA-256 `7c5fa47e7c58cc2512024c6491af4589837e9395b8171ce84dd3d0193757c511`, with profile
file-set manifest `60964784dba36f8f7d3f63e71dda413aec4dbf501bf493dd19f9a1f85311159b`. The raw input
and wrapper are preserved under
`<作業フォルダー>\TaskArtifacts\UnLhaRe\goal-restore-20261019\tokyo-population-holdout-20261020\${bt} and
`...\tokyo-population-holdout-campaign-20261020\${bt}. The payload is an independent, small structured
administrative-data screen, not broad throughput evidence. It is holdout-only; development,
training, and tuning are prohibited. The official catalog labels it CC BY without a version number;
the pinned profile preserves the source page, catalog, direct CSV URL, attribution, explicit null
license version, and note not to infer one. The CSV bytes are unchanged; only an `input/` member
name and stored ZIP wrapper are added.

The profile is wired through the worker, serial runner, lifecycle validator, and aggregator. The
immutable marker must bind these source/license fields together with all input, source, tool, script,
cap, and schedule pins before payload validation or run registration. The worker writes the same
metadata to each sample report and the aggregator checks it against the fixed profile. Current
script pins are:

| Script | Bytes | SHA-256 |
|---|---:|---|
| `storage-lifecycle.psm1` | 103,941 | `89083bd6c920fae629bc148f54531d5d2d331741a37207e7a6f4ef7ca5ab80f0` |
| `portfolio-7zip-product-screen.ps1` | 36,823 | `04661496c5f8a55bf32300eb7a326465bc04cc35542eef58580c1b2e51fb4e68` |
| `run-storage-experiment.ps1` | 41,054 | `584cea4c0b833793ff378b11c0d4cd9616db3f4649cf8549859f128c7b9bbea5` |
| `aggregate-portfolio-7zip-product-screen.ps1` | 47,002 | `cc4722fda2be17968d77bb3322094b0f317ae5bdf3b33919fe47fe59c502b3d5` |

The 37-file Rust source manifest remains
`0f549ab7f8c675b8ef241279d8ab29f90e9c7b7e32a5bc08c7effd0dc861c404`; the pinned Release CLI is
2,575,360 B, SHA-256 `3dd0e0503ed6ec11c90ad1ff9ee69b2e34c564f8710871ab182dd684f27b7b4b`; and 7-Zip
26.04 is SHA-256 `95fff19b73eff77c87c0d7bd32822e43fb90dd2932459f962eb532d8dfb6ba53`. Four-script
PowerShell AST parsing reported zero errors. The lifecycle profile and `Assert-KhcPortfolioInput`
accepted the fixed wrapper/member hashes and manifest, and an independent read-only review found no
additional integration issue. These are static/input-integrity checks only: no Tokyo campaign
marker, registration, build, candidate/7-Zip invocation, measurement, or aggregate exists yet.
Before creating the marker, perform a fresh complete storage/process/path/source/input/tool
preflight. The next external CPU start gate must be five consecutive one-second readings at or below
15%; stop on the first failure and close this exact candidate condition without retry.

#### Tokyo resident-register holdout immutable preregistration (2026-10-20)

The immutable marker is
`<作業フォルダー>\TaskArtifacts\UnLhaRe\goal-restore-20261019\tokyo-population-holdout-campaign-20261020\campaign-start.json`
(4,123 B, SHA-256 `903fa128a77e8dbfab2cd914bc391b79d26dd234ae04b6668642ebbc2f8e48d5`), campaign
`130beb8a0bd84ac4a763b719457e421b`. Its fixed registration window is 2026-10-19
21:00–21:30 UTC (2026-10-20 06:00–06:30 JST). The lifecycle validator accepted the complete marker,
source/license metadata, input wrapper, script/tool pins, and source manifest before the window
opened.

The pre-registration read-only checks passed with a 290 MiB reserve: no pending lifecycle runs,
no process using the pinned KHC CLI or 7-Zip executable, no marker/report existed before creation,
and the campaign directory contained only the pinned input ZIP. All seven D-drive artifact paths
were plain directories with no reparse point. Storage use was 1,839,176,336 / 32,212,254,720 B
total, 686,504,276 / 2,147,483,648 B external, 1,625,357,095 / 6,442,450,944 B Cargo,
190,572,106 / 1,073,741,824 B lifecycle, and D: free space was 520,304,836,608 B. The 37-file
Rust source manifest and all source/tool/script/Cargo/disk-budget/input hashes matched.

No run is registered and no candidate or 7-Zip process has started. Do not register before
`2026-10-19T21:00:00Z`; at or after that instant take the fresh five-reading external CPU
gate, stopping at the first value above 15%. Any gate or campaign-cap failure closes this exact
input/profile/window without retry. If the gate passes, run the fixed 20 one-sample lifecycle
registrations serially, completing and verifying Prunlet recovery before each next registration;
aggregation is only after the fixed deadline.

#### Tokyo holdout campaign stopped at the pre-registration gate (2026-10-20)

The fixed start gate began at `2026-10-19T21:00:23.6419329Z` and stopped on its
second sample: the first external `_Total` CPU reading was 8.97% at
`2026-10-19T21:00:25.3930677Z`, followed by 57.04% at
`2026-10-19T21:00:26.4202499Z`. The gate stopped immediately above the fixed 15%
limit; no remaining samples were taken. This closes campaign `130beb8a0bd84ac4a763b719457e421b`
for this source, input, profile, and window without retry. No lifecycle run was registered, neither
compressor was invoked, and no command or performance measurement exists. The immutable start marker
remains unchanged (SHA-256
`903fa128a77e8dbfab2cd914bc391b79d26dd234ae04b6668642ebbc2f8e48d5`); the stop evidence is
`<作業フォルダー>\TaskArtifacts\UnLhaRe\goal-restore-20261019\tokyo-population-holdout-campaign-20261020\pre-registration-stop.json`
(SHA-256 `c4fd8a647b9c84ebe718b5833663d0bf76a31c4705dfe75c4b0daf704e7e3ffd`). The prospective
gate instructions above are historical; they do not authorize a retry or imply benchmark results.

#### Livedoor independent holdout profile integrated (2026-10-20)

The ordinary-text Livedoor News archive was acquired from the fixed official URL
https://www.rondhuit.com/download/ldcc-20140209.tar.gz (8,855,190 B, SHA-256
b17606ed8c670013a3809100a9e6104701baab62cc019abc262111bd2acf1063). Its nine category
LICENSE.txt files state CC BY-ND 2.1 JP, require original-author credit, prohibit article-text
modification, and name the category content providers. The local benchmark sample preserves those
licenses and article bytes; it is not published.

The holdout-only stratified input is
<作業フォルダー>\TaskArtifacts\UnLhaRe\goal-restore-20261019\livedoor-holdout-20261020\input.zip:
191 files / 629,588 raw B, 661,042 wrapper B, wrapper SHA-256
e9d770628225650dd1b28a355f908cdf3c54b0ae68bf397776d6757cfc4a3209, file-set manifest SHA-256
4c23d4dbdd312c4d7c9efa4199ccfff30c36a33671f53421e27a0578b57beec1. It contains 180 articles
allocated proportionally by largest remainder across all nine categories (lowest lowercase SHA-256
of UTF-8 member path per category), all nine license files, and two root metadata files. Input
paths preserve the category hierarchy under input/text/; ZIP members are stored and timestamped
1980-01-01T00:00:00Z.

The fixed profile LivedoorNews2012Holdout20261020 is wired through the worker, serial runner,
lifecycle validator, and aggregator. Current script pins are:

| Script | Bytes | SHA-256 |
|---|---:|---|
| storage-lifecycle.psm1 | 132,053 | 5a430ce1eb9d6a25d8089a48673110009b39042ef5a8df38432c62e9a671c961 |
| portfolio-7zip-product-screen.ps1 | 37,935 | 0e59db21790671190d1c89f67b48c9fa5110d38c958d2d66cdeea2a612668682 |
| run-storage-experiment.ps1 | 41,185 | e3085e3a8da77abd5f214d140f97d82bee686416fbc4a9d3e763f4a4325c2b54 |
| aggregate-portfolio-7zip-product-screen.ps1 | 47,917 | 37987d0e2c399665594872e5b339beb64d9efe04b70596bc916cfd6ea6f734be |
| disk-budget.ps1 | — | 506e4c68dc05734bc1a0c02bac6f81d4677e0bcffd9b9fa2b7bd67d53319bdcd |

The exact remaining build/tool pins are Cargo.toml SHA-256
`3b47e50b8e543a5af82617bee4d4bd48ec20fc795a333ba50cbc9e439e0c2fac`, Cargo.lock SHA-256
`d8dab69b03805b559440c186ed04c2d0d0ee57eba922306cfa6827bf79985554`, CLI size 2,575,360 bytes,
and `C:\Program Files\7-Zip\7z.exe` SHA-256 above.

Metadata-only validation of the fixed ZIP checked all 191 member paths, lengths, and SHA-256 values,
the file-set manifest, stored representation, timestamp, and wrapper pin. The 7-Zip l -slt
listing-only probe returned 60,541 stdout B and 0 stderr B; the new profile-specific caps are
262,144 B / 2,048 B and leave the existing 16 KiB default untouched. A compact in-memory campaign
marker measured 5,603 B, with the 191-item listing omitted from the marker and the exact set still
pinned by wrapper and manifest hashes. Four-script AST parsing and a custom trailing whitespace
scan passed. The existing 32 MiB / 512-entry, 160 MiB/process, 60-second command, 512 KiB/report,
1 MiB aggregate, and 15% CPU limits were not expanded.

No Livedoor campaign marker was written, no run was registered, and neither compressor was invoked;
there is no performance result. The full all-history audit remains incomplete. Do not use this
holdout for training or tuning, and do not claim general superiority from this screen alone.

#### Livedoor independent holdout fixed campaign preregistration (2026-10-20)

The next Livedoor screen is fixed as campaign `e54b2fcd559640d583e3e89e631bca50`, with an immutable
marker at
`<作業フォルダー>\TaskArtifacts\UnLhaRe\goal-restore-20261019\livedoor-holdout-20261020\campaign-start.json`.
Its exact UTC window is 2026-10-19 21:40:00–22:10:00 UTC (2026-10-20 06:40:00–07:10:00 JST).
The marker is written (5,299 bytes, SHA-256
`5f53c86c7eb3c54cc33c9a08a71dbb5fdd46ff96767d6c9f1b2944476310ee2c`) and passed static lifecycle
validation in the `goal-restore-20261019` context before the window opened. No run is registered;
the fresh resource/process/path/hash preflight and five-sample CPU gate remain required.

The holdout remains the fixed 191-member, 629,588-byte Livedoor News 2012 stratified sample
(`input.zip`: 661,042 bytes, SHA-256 `e9d770628225650dd1b28a355f908cdf3c54b0ae68bf397776d6757cfc4a3209`;
manifest SHA-256 `4c23d4dbdd312c4d7c9efa4199ccfff30c36a33671f53421e27a0578b57beec1`). The Rust source
manifest is pinned to `0f549ab7f8c675b8ef241279d8ab29f90e9c7b7e32a5bc08c7effd0dc861c404`, release CLI
to `3dd0e0503ed6ec11c90ad1ff9ee69b2e34c564f8710871ab182dd684f27b7b4b`, and 7-Zip 26.04 to
`95fff19b73eff77c87c0d7bd32822e43fb90dd2932459f962eb532d8dfb6ba53`. Campaign script pins are:

| Script | Bytes | SHA-256 |
|---|---:|---|
| storage-lifecycle.psm1 | 132,053 | 5a430ce1eb9d6a25d8089a48673110009b39042ef5a8df38432c62e9a671c961 |
| portfolio-7zip-product-screen.ps1 | 37,935 | 0e59db21790671190d1c89f67b48c9fa5110d38c958d2d66cdeea2a612668682 |
| run-storage-experiment.ps1 | 41,185 | e3085e3a8da77abd5f214d140f97d82bee686416fbc4a9d3e763f4a4325c2b54 |
| aggregate-portfolio-7zip-product-screen.ps1 | 47,917 | 37987d0e2c399665594872e5b339beb64d9efe04b70596bc916cfd6ea6f734be |

The preregistered sequence is 20 separately registered single-sample runs: round 0 warms each
method; rounds 1–9 are measured. Even rounds (0, 2, 4, 6, 8) run candidate (`portfolio-trial`)
then 7-Zip; odd rounds (1, 3, 5, 7, 9) run 7-Zip then candidate. Each method is registered and
invoked once in its position. The candidate uses one create thread and four extract workers; 7-Zip
uses solid LZMA2 level 9, a 64 MiB dictionary, one create
thread and four extract threads. A pass requires deterministic candidate archive bytes, exact full
restore and hashes, candidate size at most 95% of 7-Zip, and candidate create/extract medians no
slower than 7-Zip. The exact 7-Zip create options are
`-t7z -mx=9 -m0=lzma2:d=64m -mmt=1 -ms=on -mqs=off -mtm=off -mtc=off -mta=off`; extract is
`x -mmt=4`. Each run is capped at 32 MiB, 512 entries and 300 seconds; each command at 60
seconds and each child process at 160 MiB. Listing capture is capped at 262,144 stdout bytes and
2,048 stderr bytes. The storage preflight reserves 290 MiB; campaign wall time is at most 1,800
seconds. The external start gate and each worker command retain the fixed five-sample CPU ceiling
of 15%.

Before the window, verify the marker, no pending lifecycle run, 290 MiB reserve, free-space and
non-reparse path chain, no candidate/7-Zip processes, and every input/tool/source/script/dependency
pin. At or after 21:40:00 UTC, take five external one-second `_Total` CPU samples; all must be at
most 15%. Any failed preflight or CPU sample permanently closes this exact campaign condition:
do not register, retry, change the window, or relax a bound. Once registered, run serially through
`run-storage-experiment.ps1`, preserve each recovery report, and finish each run's lifecycle using
the documented direct-CMD Prunlet process before registering the next. Stop at the first cap,
timeout, command, cleanup, CPU, or deadline failure; do not replace a failed run. Only a complete
20-run sequence may be aggregated. This is one independent text-corpus family, not a broad claim
of general superiority or completion of the overall performance objective.

#### Livedoor fixed campaign closed at the internal CPU gate (2026-10-20)

Campaign `e54b2fcd559640d583e3e89e631bca50`, marker SHA-256
`5f53c86c7eb3c54cc33c9a08a71dbb5fdd46ff96767d6c9f1b2944476310ee2c`, reached its fixed window.
The fresh external start gate passed all five samples: 1.23%, 6.46%, 3.19%, 3.34%, and 0.92%
(21:40:23.8699976–21:40:27.9107946 UTC; limit 15%). The first and only registered sample was
round 0 / `portfolio-trial`, run ID `ca3ed67c85374757ae61ca5321d5bd04`. Its internal five-sample
gate stopped immediately on sample 4: 0%, 1%, 13%, then 19% at `2026-10-19T21:41:05.2847043Z`,
over the fixed 15% cap. The report says `CPU gate failed before 0-portfolio-trial-create : 19
percent; no retry.` The timed create command was never started (`wall_ms=0`); no candidate archive,
7-Zip timed create/extract, size comparison, speed measurement, or aggregate result exists. The
untimed 7-Zip and KHC version probes exited 0. This closes the exact Livedoor campaign condition;
do not register another sample, retry this input/window/settings, or relax the gate.

The registered work tree was 710,459 B. Direct-CMD Prunlet staged deletion and purge completed as
operation `c568a0cf2caf489fa56d008a0b400657` (206 entries); lifecycle finalization records
`BeforeBytes=710,459`, `AfterBytes=0`, `State=complete`. `Test-KhcStorageCompletedReceipts` passed;
no candidate/7-Zip process or pending lifecycle run remains. The Prunlet backup was purged only
after the recovery archive and receipts were verified. Evidence retained under
`<作業フォルダー>\TaskArtifacts\UnLhaRe\goal-restore-20261019\storage-lifecycle\runs\ca3ed67c85374757ae61ca5321d5bd04\`:

| Artifact | Bytes | SHA-256 |
|---|---:|---|
| `run.json` | 376 | 278796e7384c5f0782c42c2f1b4ae34818f8d2426fa60d50925fb9e7ca92a4f3 |
| `runner-result.json` | 540 | bf0f0985800b1a2e71100102bca7384f77b52354cff4f63ee4995a22ae0b0191 |
| `recovery.zip` | 468,018 | 290be36687247d08d41ea7db6c0901e8c93805340c61ba770cf25f17484ab04f |
| `recovery.json` | 62,148 | 1879871d2375b70701a8529f51fd58e1017f4fd4791a13e2efba54a6cc12cd47 |
| `portfolio-product-report.json` (inside recovery ZIP) | 80,871 | ee2bd22b3e4bd83fde228508669c4efeb4ed1c24572ec8135cd2fdcb051413f7 |
| `cleanup-request.json` | 63,171 | c2bb0c9fd78474a85f56ee7ea0195d206dfd2190e92e16f3e1728ff31635dba7 |
| `complete.json` | 1,591 | 06f3045d3973f1dc602f8e21aba6fd50529979dd675b8e253335c2a2da868059 |
| `cleanup/delete-preview.json` | 48,368 | f0e546f39c25f4dc6ebb11f2a8c62a6dd06bf1bf6e963f284763bacb1e78c03a |
| `cleanup/delete-result.json` | 75,209 | 1d250a35c865dbbe2d06c2cafb93bcdd92dd2cc19786781e2d39dd1a2cf149e6 |
| `cleanup/purge-preview.json` | 76,076 | de93a817febe17c9cb1d8b2e71378ba40783658935ba143b1b9b5ef37bb508a0 |
| `cleanup/purge-result.json` | 75,122 | 88132b219f87e37fa7a0036928b1c0774407d8a2aa0154fc4c51687e7a1724ee |

#### UCI tabular profile remains metadata-only and closed to execution (2026-10-20)

`UciTabularDevelopment20261020` records UCI Bike Sharing `hour.csv`, Steel Plates Faults
`Faults.NNA`, and Abalone `abalone.data` for development/tuning only. These inputs are not a
blind holdout, independent evaluation, or evidence for the final 13-category aggregate. The
profile is deliberately `ScreenReady=false`; no input wrapper or campaign marker was created.

The Bike publication is now identified and recorded in lifecycle metadata as:
Fanaee-T, H., & Gama, J. (2014). *Event labeling combining ensemble detectors and background
knowledge*. *Progress in Artificial Intelligence*, 2(2–3), 113–127.
https://doi.org/10.1007/s13748-013-0040-3. The [UCI Bike Sharing page](https://archive.ics.uci.edu/dataset/275/bike+sharing+dataset)
identifies it as the introductory paper and labels it 2013; the [Springer publisher record](https://link.springer.com/article/10.1007/s13748-013-0040-3)
records online publication on 2013-11-26 and volume/pages as 2014.

Execution remains blocked until a fixed input wrapper and manifest are established and the
member-level notices/rights are resolved. The metadata and current candidate provenance are
documented in `RESEARCH_SELECTION_20261005.md`. Do not treat dataset-page licensing as proof for
unverified member notices.

The metadata-only wiring spans four scripts. Static validation and independent review found no
actionable P1/P2 issue. All four PowerShell files parse with zero errors and have no trailing
whitespace. The profile is rejected before input payload access, campaign registration, worker,
aggregation, or recovery. No UCI member payload was opened or parsed; no candidate/7-Zip
benchmark, run, aggregate, or performance result exists.

| Script | Bytes | SHA-256 |
|---|---:|---|
| `storage-lifecycle.psm1` | 137,934 | `4e0f1db6a71dfd896072bef215efda6adcb1f2c74d65472d98a074839eb40be4` |
| `run-storage-experiment.ps1` | 41,455 | `66f382d657f01e0676d91c0650ab0b7489704f74186efbd66e53a9aba32c4e92` |
| `portfolio-7zip-product-screen.ps1` | 38,289 | `86f4887c7925fc503e31e7a2df3a3f9eeb1b8a442ee201f674e6e4fa165ca7ec` |
| `aggregate-portfolio-7zip-product-screen.ps1` | 48,271 | `e5aa9914de676567d907b8724f028c9cebba76b4552b254893030e6644f4929a` |

The Rust source manifest remains `0f549ab7f8c675b8ef241279d8ab29f90e9c7b7e32a5bc08c7effd0dc861c404`;
the Release CLI pin is `3dd0e0503ed6ec11c90ad1ff9ee69b2e34c564f8710871ab182dd684f27b7b4b`. These are
metadata/profile-wiring pins only, not a build or benchmark receipt.

#### Livedoor recovery validator routing correction (2026-10-20)

The abandoned-run recovery dispatcher now selects `Assert-KhcLivedoorHoldoutCampaign` for
`LivedoorNews2012Holdout20261020`, while retaining the dedicated JMA and Tokyo validators for
their respective holdouts. UCI remains rejected before the dispatcher and e-Gov/Aozora retain
their existing paths. Independent read-only review found the dispatch consistent with profile
definitions and recovery control flow; PowerShell parsing passed. No recovery operation was run:
the prior Livedoor campaign is already closed and cleaned, and there was no pending run to recover.
This is a future recovery-routing fix, not a change to that historical campaign result.

#### NICT Kyoto Wikipedia parallel corpus screen input frozen (2026-10-20)

The candidate is NICT's *Wikipedia日英京都関連文書対訳コーパス* Version 2.01. The official
[NICT corpus page](https://alaginrc.nict.go.jp/WikiCorpus/) dates v2.01 to 2011-01-13, lists an
approximately 74 MB archive, and grants use/redistribution under CC BY-SA 3.0 with a recommended
credit. The [official README](https://alaginrc.nict.go.jp/WikiCorpus/src/readme.pdf) describes
one UTF-8 XML per article, 15 category directories, and article-level copyright-holder lists.
NICT cautions that articles may contain defamatory, discriminatory, or personal information. This
is not a legal determination. Evaluation remains local; do not publish article text, titles, wrapper,
or source-derived output. Preserve the NICT credit and license in provenance. Reports may include
aggregate metrics, counts, and hashes only.

The official archive was acquired from
`https://alaginrc.nict.go.jp/WikiCorpus/src/wiki_corpus_2.01.tar.gz`: 74,096,805 bytes,
SHA-256 `456172bdd1d7a32dbe68ae3e55e0a6de25a4f40582636fd7712a5404319a10e5`. A first metadata-guided
wrapper contains 512 XML members / 14,014,059 payload bytes / 14,069,377 ZIP bytes, SHA-256
`5e5c790274d4ada68e3750160255cdf28d08f96d704ca85deb01aa8fb33e55a3`; its member manifest SHA is
`e13a2d1ad52204887bedb6c820d9a6b82f44a8210644b86796f25899aba2f780`, inventory SHA
`71b0e0df30551bd5e216ff27b63c3c6d9909c07c576aa572b0f605bbc41b9da4`, and acquisition record SHA
`2aae2b5db8706ce9697673e9f2341bea26ec94acecebd9858f5fd887c9c16cd3`. It was not benchmarked and is
rejected as the screen input: the worker caps the entire working tree at 512 entries, including
both source and restored files plus directories and report reservation.

To retain the fixed 32 MiB / 512-entry cap, the frozen recipe is now 195 members, exactly 13 per
official category. The metadata-only selector sorts each category by SHA-256 of canonical UTF-8
relative path (ordinal path tie-break), then chooses one per category in ordinal category order for
13 rounds. Total payload must remain at or below 32 MiB minus 128 KiB; no content-based reselection is
allowed. The selected metadata manifest is
`<作業フォルダー>\TaskArtifacts\UnLhaRe\goal-restore-20261019\nict-wiki-holdout-20261020-195-entry\selection-manifest.json`,
36,730 bytes, SHA-256 `c575b295d3afff9e057fc078688caf71b5d9edae849d1d9bc637fd2b4db73e09`. It contains only
paths, category codes, path hashes, and sizes; it fixes 195 members / 5,236,133 payload bytes, with
13 members in each of BDS, BLD, CLT, EPR, FML, GNM, HST, LTT, PNM, RLW, ROD, SAT, SCL, SNT, and TTL.
The final packager verified this exact SHA and recomputed path/size set before reading selected member
data. It created a deterministic `ZIP_STORED` wrapper with 1980-01-01 timestamps, no root prefix,
comments, or extra fields. The wrapper is
`<作業フォルダー>\TaskArtifacts\UnLhaRe\goal-restore-20261019\nict-wiki-holdout-20261020-195-entry\input.zip`,
5,257,215 bytes, SHA-256 `aee6335bc9f43f35e5c29c3944cb8067eefed618578c02c8faac4ff4112c5ecd`. Its 195 stored
members / 5,236,133 payload bytes were independently matched to the selection and member manifests;
all member SHA-256 values and ZIP metadata matched. The manifest-derived file-set SHA-256 is
`cad92e76db4142c15c32b924f8906320a38fff42638d1cdc69e5a9ed157b66f5`. Pinned 7-Zip 26.04 ran
`t -tzip -bb0 -bsp0 -bso0` on the wrapper and exited 0 (63 ms); this separate command supplied the
ZIP CRC validation, while the preparer performs member SHA readback only.

The work-only preparer is `<作業フォルダー>\UnLhaRe\goal-restore-20261019\prepare-nict-holdout.ps1`,
SHA-256 `2070319bd1847534213febb30051d8d2a102124b758f692e2c8d764b802e9dc0`. Its metadata-only pass
created and validated the frozen manifest without outputting article text. The acquisition record
preserves the source archive, license, handling, and NICT-recommended attribution. The same NICT-theme
Plumivox query `日本語 コーパス オープンデータ` returned zero posts with
`completeSearch=false`; the current Toolport connection refused a fresh lookup, so the existing
non-exhaustive result is reused and is not evidence of absence.

Final TaskArtifacts: `member-manifest.json` 65,265 bytes / SHA-256
`21cab6251284f8b020c66756e9a96e711fa76abf4fea1f8342ef83d894504748`; `archive-inventory.json`
2,143 bytes / SHA-256 `f9cccf4b35220e8b95e33477778d5636dc71c58072ef319dee9b7b181d40217e`;
`acquisition-record.json` 1,221 bytes / SHA-256
`4a2dcd95379f4af5aab54fcb04d97e9cd733ef23fa2e841ea0d7b0c2f4e3f8ae`. The exact input and all
provenance files remain outside the repository.

Profile wiring, campaign marker, registration, candidate/7-Zip timing comparison, and performance
result do not exist yet. The frozen input can only support one independent source family, not a broad
superiority claim or GOAL completion. Update the Selection document's STORAGE hash after this section
is complete and again after any later profile records are appended.

#### NICT holdout profile wiring and redaction review (2026-10-20)

`NictWikiCorpusHoldout20261020` is now wired through the fixed portfolio worker, runner, lifecycle
validator/recovery dispatcher, and aggregate script. The lifecycle pins the frozen wrapper at the
path, length, and SHA above; checks all 195 entries, member hashes, stored lengths, timestamps, and the
ordinal file-set digest; and validates the immutable campaign marker and four provenance artifacts
before any NICT payload read. The marker omits duplicate member rows to remain below the existing
32 KiB limit. The profile is holdout-only, one source family, and unavailable for tuning or training.

The existing screen protocol remains fixed: 20 serial single-sample runs, round 0 warmup and rounds
1–9 measured with alternating first strategy; 32 MiB / 512 entries / 300 s per run; 1,800 s overall;
60 s per timed command; 160 MiB child-process memory; five external `_Total` CPU samples at or below
15% before registration and each command; stop on the first failed gate. Candidate create uses one
thread and extract uses four. The 7-Zip 26.04 comparison uses solid 7z/LZMA2 level 9, 64 MiB
dictionary, one create thread and four extract threads. The predeclared pass conditions remain
candidate archive size at most 95% of 7-Zip and candidate median create/extract times no slower.
The input is a narrow stratified 195-member sample, not a broad representative corpus; its result
alone cannot establish general superiority or complete the goal.

The holdout profile and report handling are pinned to these current files:

| File | SHA-256 |
|---|---|
| `storage-lifecycle.psm1` | `f4b082ccee1abfa14616410b4319e66386b05ab8405e32108dd518146ac23d42` |
| `run-storage-experiment.ps1` | `55bbcea28bb2230d7e546c3915530164258ef020e1134734bd5092e058c9c134` |
| `portfolio-7zip-product-screen.ps1` | `ac1d99edf74a065db86b87b42626802878b7312576941d3199e0888e51849332` |
| `aggregate-portfolio-7zip-product-screen.ps1` | `73cb52f02e9cfde35e6bb2fe918e63f75ddf661b2f3cd2d943241ff585a7b481` |

The Rust source manifest remains 37 `.rs` files, SHA-256
`0f549ab7f8c675b8ef241279d8ab29f90e9c7b7e32a5bc08c7effd0dc861c404`; the candidate CLI remains
SHA-256 `3dd0e0503ed6ec11c90ad1ff9ee69b2e34c564f8710871ab182dd684f27b7b4b`, and 7-Zip 26.04 remains
SHA-256 `95fff19b73eff77c87c0d7bd32822e43fb90dd2932459f962eb532d8dfb6ba53`. The four provenance
artifact hashes were rechecked against the fixed NICT profile without opening source text.

Independent review found a privacy defect in the worker's finalization catches: a path-bearing
exception from final inventory, storage validation, or report save could have reached console output
or the runner error. The worker now replaces every NICT finalization error and final thrown error with
a fixed content-free record while preserving existing diagnostics for other profiles. A second
read-only review found no P1/P2 after the fix. PowerShell AST parsing for all four scripts passed;
an in-memory synthetic path-bearing exception verified NICT redaction and unchanged non-NICT error
behavior; all six touched scripts/docs have no trailing whitespace. No NICT payload was read in this
verification, and no campaign marker, run registration, compression, extraction, or performance
measurement exists yet. This profile is wired but not preregistered; do not treat setup validation as
a holdout result.

#### NICT holdout campaign preregistration (2026-10-20)

The wired NICT profile is preregistered as campaign `9dd033d334034bbeaa1861acd9b98e0f` with
immutable marker
`<作業フォルダー>\TaskArtifacts\UnLhaRe\goal-restore-20261019\nict-wiki-holdout-20261020-195-entry\campaign-start.json`,
5,291 bytes, SHA-256 `cbc2724fe152bf070ee46c8c58a5593cbbb81af4796008aff2a829731c622d8b`.
The fixed window is `2026-10-19T22:50:00Z`–`2026-10-19T23:20:00Z` (2026-10-20 07:50–08:20 JST).
The marker pins the NICT provenance metadata, all four profile scripts, Rust source manifest, CLI,
7-Zip, wrapper, member/file-set metadata, 20-run alternating schedule, and comparison settings.

At preregistration, no payload or sample had been evaluated. The required fresh process/path/reparse/
lifecycle/storage preflight and external CPU gate are recorded below. The protocol requires five
external CPU samples at or below 15% before registration and each timed command, stopping immediately
on the first failed or missing counter, with no retry or window shift. If admitted, the campaign would
run exactly 20 serial single-sample registrations with lifecycle cleanup before each next registration
and stop on any failure, cap, or 1,800-second campaign limit. No marker, source, threshold, or timing-
window changes are allowed after registration opens. This single-family holdout cannot establish broad
superiority by itself.

#### NICT holdout campaign stopped before registration at external CPU gate (2026-10-20)

The fixed window opened at `2026-10-19T22:50:00Z`. The fresh read-only preflight passed at
`2026-10-19T22:50:55.6234404Z`: the NICT metadata gate and plain-path/reparse checks passed, no
pending run or relevant process existed, and the 290 MiB reserve remained within the 30 GiB total,
2 GiB external, 6 GiB Cargo, 1 GiB lifecycle, and 5 GiB free-space limits. At that point D: had
`516,536,950,784` bytes free; the measured total was `1,943,306,113` bytes, external regular usage
`317,949,018` bytes, Cargo `1,625,357,095` bytes, and lifecycle `191,444,613` bytes.

The external `_Total` CPU gate began at `2026-10-19T22:51:21.0017338Z`. Samples were 10%, 14%,
13%, then 19% at `2026-10-19T22:51:28.7369312Z`, exceeding the fixed 15% maximum. Collection
stopped immediately at sample 4; no fifth reading, run registration, compression, extraction,
aggregate, retry, or window rebase occurred. A post-stop check confirmed zero pending runs, zero
relevant processes, and zero new run directories. The source/input/window condition is closed.
Machine evidence is `<作業フォルダー>\TaskArtifacts\UnLhaRe\goal-restore-20261019\nict-wiki-holdout-20261020-195-entry\pre-registration-stop.json`
(1,760 bytes, SHA-256 `efd25d722d716c47a0f90423b04aa96830fbd7681d87649bd446ad66f81fbfb4`).
This is a resource-gate stop, not a performance result or a format-level no-go.

### Frozen historical archive revision 1–9 compatibility E2E preregistration (2026-10-20)

The existing revision-1–9 E2E creates each archive with the current writer and then reads it with the
current decoder. That proves the current writer/reader pair, not compatibility with bytes emitted by
an earlier source version. This separate finite E2E supplies frozen archives retained from the
completed 2026-10-19 revision-9 run `e60b9d1bbec149d68208c27485165d9b`; it does not encode or tune a
new candidate.

The fixed input is
`<作業フォルダー>\TaskArtifacts\UnLhaRe\goal-restore-20261019\storage-lifecycle\runs\e60b9d1bbec149d68208c27485165d9b\recovery.zip`
(453,632 B, SHA-256 `e20d93ace231af1192153a4cadc0feb43a6922687d2e32a02dcb3ac608c97f28`; archived
manifest SHA-256 `b3ff388ab9a6eb73d289f36aeed11ab98a283b608d1c276cf0d959029de45bd5`). The prior run
record pins its writer source as `src/khc/mod.rs` `c3335017f8905364f66d797f992f10ba54a50707116cb224304acc4470ec41fa`,
`src/main.rs` `35ee6bd7a7d222db03f92a1647155c678d752b9a69e793b4749a665fa57c72aa`, and
`src/khc/block/mod.rs` `861da675a6eee403e51a7d2130ad80414da765c72a5e37eca6966084067fd748`. The current
reader is pinned to the 37-file source manifest `0f549ab7f8c675b8ef241279d8ab29f90e9c7b7e32a5bc08c7effd0dc861c404`,
27-file KHC source manifest `15a4ec2660cd8eecf83743ce347173c971c822c0ce95e0155672c5ed19635500`,
`src/khc/mod.rs` `4613ed1e1fdcbdfe5ece704e47ecff23213e5621a4b6c0839f02712e155da7f3`,
`src/khc/record.rs` `9527239e9be4e31680273420260697b26fdddda68a7434d9e1628495d90697b6`, and Release
x64 MSVC CLI `unlhare-cli.exe` (2,575,360 B, SHA-256
`3dd0e0503ed6ec11c90ad1ff9ee69b2e34c564f8710871ab182dd684f27b7b4b`).

The worker validates the complete recovery-ZIP hash, source-reference hashes, exact archive member
names/sizes/hashes, and the revision byte before invoking the current CLI. Each archive must pass
`khc-test`, extract to a fresh per-revision directory, publish only the expected file set, and
restore every file to its frozen length and SHA-256. Revisions 1–8 restore `legacy.bin` (1,088 B,
SHA-256 `3152d80f27ad1d7663f85373304e606811d3c421bbb54249b840415811621e71`); revision 9 restores
`ptt5.bin` (513,216 B, SHA-256
`0ec3a75089bb52342813496b17e51377bc9eba3cb519a444d67025354841d650`) and `short.bin` (9 B,
SHA-256 `073f8a6663fc49fd74e1e6dfd4d18d0bffb6e9a2af848e7adfbd4a567fbf732c`).

| Archive revision | Frozen recovery member | Bytes | SHA-256 |
| ---: | --- | ---: | --- |
| 1 | `api/legacy-1.khc` | 432 | `e0d9968fbe92cb248d1e177ae03dd755accf58c27b1acefdf5b5ae3964d7bfc5` |
| 2 | `api/legacy-2.khc` | 161 | `597cb528c4df6416c4a0e047faf0c4e6d870b9e4ba1a52e7b7039b1281495b07` |
| 3 | `api/legacy-3.khc` | 235 | `b596d4eb9a545503a5412f4d3c4c10da5ba1214da2a346713442fa47ba5d8000` |
| 4 | `api/legacy-4.khc` | 235 | `0a6cca6c7c79bdce6bf9c0ff1b8dcb3ae9c3e7f2d35d557ae720fe54ca85149c` |
| 5 | `api/legacy-5.khc` | 248 | `5c53fcce0a6a0f2abaf91f5e9223fef95adca9a35377d40161d1f371f691c0da` |
| 6 | `api/legacy-6.khc` | 238 | `98df162d59a0c713177423ba9e0d4126003e6e3950e5161934f2e0282c4a186c` |
| 7 | `api/legacy-7.khc` | 170 | `432fa33c7597905f374960ebf22082b9a6d41d985bd00cdb595fa00e6f43bbff` |
| 8 | `api/legacy-8.khc` | 238 | `e2654a66c31b8d1379794aaea58e23bc9620ed238419244f667adc3ae1386d2a` |
| 9 | `cli-revision-9.khc` | 40,051 | `4abe41073bd9a3098b5cde58585d4f54c434c04e1514c72d533de61972f45fe6` |

One registered invocation of `historical-archive-compat-e2e.ps1` through
`run-storage-experiment.ps1` is allowed at 5 MiB / 64 entries / 300 seconds. The worker pin is
`1eea21fd72f694ed9249a0058ce45beed47d3fe70f6133511beb17437146aa44`; the modified registered-run
allowlist pin is `c765108702eda55fd38e33fa2b46df59d4e188f4092c5ddc9210ff221678916c`, lifecycle pin
`f4b082ccee1abfa14616410b4319e66386b05ab8405e32108dd518146ac23d42`, and disk-budget pin
`506e4c68dc05734bc1a0c02bac6f81d4677e0bcffd9b9fa2b7bd67d53319bdcd`. The staging plan writes
only the nine frozen archives, up to ten restored files, and a hash-only JSON result; the expected
payload footprint is under 1 MiB within the fixed 5 MiB / 64-entry cap. The registered-run
preflight, child timeout, recovery receipt, and Prunlet cleanup remain mandatory.

The sole acceptance condition is successful verify/extract and exact per-file path, length, and
SHA-256 equality for all nine frozen revisions. A source/input pin mismatch, unexpected file,
nonzero CLI exit, resource-cap failure, timeout, or cleanup/receipt failure stops this condition;
do not retry the same registration after a failure. This is historical read-compatibility evidence
only—no compression, 7-Zip comparison, timing, memory-efficiency, or superiority claim is made.

#### Completed frozen historical archive compatibility E2E (2026-10-20)

The single registered run `0d9ce97e92ae49aeab852b57d6fd04ab` passed all nine frozen archives:
revisions 1–8 each passed current CLI `khc-test` and `khc-extract`, restoring the 1,088-byte
`legacy.bin` to SHA-256
`3152d80f27ad1d7663f85373304e606811d3c421bbb54249b840415811621e71`. Revision 9 passed both
commands and restored `ptt5.bin` and `short.bin` to their pinned hashes above. The pass did not use the current writer to
regenerate these inputs. A read-only check of the retained recovery ZIP independently matched all
nine archive hashes, revision bytes, CLI exit codes, output paths, output lengths, and output hashes.

| Retained evidence | Bytes | SHA-256 |
| --- | ---: | --- |
| `historical-archive-compat-e2e.json` in the recovery ZIP | 5,047 | `7a263900101902b9c82a294cba2904f3ac57e63b9c7b08b4781218dae01a3a6a` |
| Full recovery ZIP | 130,202 | `f1a629c8cffd802e3014d9c726990de8da3d8b7c5318113b5f8800bdbf1c0a2c` |
| Recovery manifest | 7,121 | `3713f4e7e47890e93d54a64d7e28205aa30eea36ec0e3c08d1c114d59bc6557b` |

Prunlet operation `4e71e1f0d4b14e459450800080e48c18` passed the complete staged delete and purge
flow. The 568,984-byte registered work tree was removed, its temporary Prunlet recovery copy was
purged after receipt validation, and `complete.json` records `State=complete`, `BeforeBytes=568,984`,
and `AfterBytes=0`. The work directory is absent; the pinned task recovery ZIP and lifecycle records
remain under `<作業フォルダー>\TaskArtifacts\UnLhaRe\goal-restore-20261019\storage-lifecycle\runs\0d9ce97e92ae49aeab852b57d6fd04ab`.

This adds historical fixture coverage beyond same-writer round trips, but it is still a finite set
of one archive per revision (revision 9 has two files); it does not prove compatibility with every
archive emitted by all intermediate source versions. It is correctness evidence only, not a
compression or performance result.

### Count-only rANS scheduled candidate-size correctness E2E preregistration (2026-10-20)

The scheduled KRS2/KRS3 length evaluator now shares the same rANS state transitions and output-limit
checks as normal finalization, but counts renormalization bytes instead of allocating the discarded
payload. It also computes the validated inner-frame length without allocating that frame or running
its CRC. The materializing encoder still uses the same finalization and `pack` checks. Candidate
ordering, strict size comparison, fallback behavior, candidate-local models, and the conservative
64 MiB memory gate remain unchanged; length-only accounting charges the hypothetical materialized
frame capacity. This bounded run checks exact restoration and that the encoded data bytes remain
identical to the fixed pre-change baseline. It is not a speed, memory-efficiency, 7-Zip, holdout, or
GOAL-completion result.

| Fixed pre-run artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| Full `src/**/*.rs` manifest (37 files, ordinal relative-path order) | — | `0130fd767098a310f299e193d193a546800dbd76cc41d0793075ae2aaaca23e1` |
| `src/khc/**/*.rs` manifest (27 files, ordinal relative-path order) | — | `c92e39dd7500a6edec561073352747db6df237557c644305d84ca0d93f65902e` |
| `src/khc/record.rs` | 44,200 | `8a99e2e57a1ee82c3eb707bd1cec04a856f7abb3d40463287f205fc0b3480af9` |
| `src/khc/record_entropy.rs` | 6,903 | `4aa84abdbe39bae54c7d25462699dc5213c526328042a6d8b58f071accb318ce` |
| `src/khc/mod.rs` | 36,061 | `4613ed1e1fdcbdfe5ece704e47ecff23213e5621a4b6c0839f02712e155da7f3` |
| `examples/khc_spatial_mdl_e2e.rs` | 22,744 | `9d834c3c255fe2e14b920c47fca309bb1cb8d4e517b19ffc4221ede6faffd07c` |
| `Cargo.toml` / `Cargo.lock` | 1,414 / 30,555 | `3b47e50b8e543a5af82617bee4d4bd48ec20fc795a333ba50cbc9e439e0c2fac` / `d8dab69b03805b559440c186ed04c2d0d0ee57eba922306cfa6827bf79985554` |
| `spatial-mdl-e2e.ps1` / `run-storage-experiment.ps1` | 11,596 / 41,692 | `099153c0493f6e8d1736f52cebdbf044c50baf64f0310c55f0bcdb0ab0177b8b` / `c765108702eda55fd38e33fa2b46df59d4e188f4092c5ddc9210ff221678916c` |
| `run-serial-cargo.ps1` | 9,859 | `053532f8fa0266b23a6dcc02e60bfb54e94d5d58d874a71692df51dec16a158f` |
| `storage-lifecycle.psm1` / `disk-budget.ps1` | 144,916 / 2,004 | `f4b082ccee1abfa14616410b4319e66386b05ab8405e32108dd518146ac23d42` / `506e4c68dc05734bc1a0c02bac6f81d4677e0bcffd9b9fa2b7bd67d53319bdcd` |
| Release x64 MSVC `unlhare-cli.exe` | 2,576,896 | `25eb2b4895616906ff3a8d04b95ae3b5a199401f97bc4b5d7a194fa7848062da` |
| Release x64 MSVC `khc_spatial_mdl_e2e.exe` | 1,666,560 | `0bf7e51aaa284a5f09f7c95a16da6e3cf55a3df1842118eb792f7cb93884d47d` |
| Fixed recovery ZIP (`input/ptt5`: 513,216 B) | 769,634 | `882e7108870c3de5d20de6e87ffc89f390c5d34630930aef73baed9171557f75` |
| Prior E2E archive data suffix at offset 89 (39,962 B) | 39,962 | `5f66e0e3552647ce66ce6020dca6c1abae889e9bfcd3ef5b94669d5fb4364977` |

The suffix baseline was independently read from the retained prior run `f66bb7133a5e46888d54003e3b594ff4`:
its 40,051-byte CLI archive differs from an earlier run only in the timestamped manifest and header
checksum; the 39,962 data bytes at offset 89 match. The fixed input ZIP and ptt5 member were rehashed
before this preregistration.

The locked/offline Release build for target `x86_64-pc-windows-msvc`, CLI, and E2E example used
`run-serial-cargo.ps1 -TransientMiB 256`. Cargo finished in 62 seconds, but that first wrapper call
returned 1 because `VCTIP.EXE` remained in its Job after the 2-second drain grace; the process exited
without being killed. One identical no-op invocation then returned 0 (`Finished` in 0.12 seconds).
The successful no-op wrapper sampled 1,634,579,414 B at start/peak/end against the fixed
6,175,228,536 B Cargo cap. The first build attempt sampled 1,634,563,700 B at start, 1,641,211,787 B
peak, and 1,634,579,414 B at end. Neither invocation deleted files. The Release executable hashes
above were read after the successful wrapper result.

Register exactly one `spatial-mdl-e2e.ps1` run through `run-storage-experiment.ps1` using the fixed
recovery ZIP, these executable hashes, an 8 MiB / 96-entry / 300-second outer limit, and the fixed
240-second child timeout. Require all preregistered revision-10 safety, compatibility, and round-trip
checks, then compare the new archive's bytes from offset 89 to the pinned 39,962-byte suffix hash.
The full archive hash may vary with serialized file timestamps and its header checksum. On any
registration, E2E, cleanup, or suffix-comparison failure, preserve recovery evidence and do not retry
this unchanged source/input condition. Immediately before registration, the read-only 25,165,824 B
reservation passed: total 3,107,717,384 / 32,212,254,720 B; external 1,952,715,531 /
2,147,483,648 B; Cargo 2,787,251,474 / 6,442,450,944 B; lifecycle 191,629,952 /
1,073,741,824 B; free D-drive space 513,697,542,144 B. `Assert-KhcNoPendingStorageRuns` passed
across both lifecycle roots, no related Cargo/CLI/E2E/VCTIP process remained, and the checked D-drive
task/workspace/TaskArtifacts ancestor chains contained no reparse points. These are the fixed
pre-registration conditions for the single run documented below.

#### Completed count-only rANS candidate-size correctness E2E and cleanup (2026-10-20)

The one preregistered run `b2494857ce574ce497f3a5331af99b02` completed successfully. All 34 child
checks had their expected outcomes: 14 successful commands and 20 intentional invalid/no-replace
rejections. The API path created revision 10 with eight frames, rejected nine malformed archives,
read revisions 1–9, and exercised its memory-reservation guard. The CLI created, listed, tested, and
extracted a two-file archive totaling 513,225 B; both restored file hashes matched their inputs:
`ptt5.bin` 513,216 B SHA-256
`0ec3a75089bb52342813496b17e51377bc9eba3cb519a444d67025354841d650`, and `short.bin` 9 B SHA-256
`073f8a6663fc49fd74e1e6dfd4d18d0bffb6e9a2af848e7adfbd4a567fbf732c`.

The CLI archive was 40,051 B with SHA-256
`66df48f7cff9e5523d181ab47095688345159aeab463c7a47e6f0376540738af`. Its 39,962 data bytes at
offset 89 exactly matched the preregistered baseline SHA-256
`5f66e0e3552647ce66ce6020dca6c1abae889e9bfcd3ef5b94669d5fb4364977`. The report was 7,162 B,
SHA-256 `0e40433b9d34ec9e1768a5feb5994bdb399d0ece03d0912b5326961387ad65cb`. The full archive hash
is timestamp-sensitive; the data-suffix match confirms byte identity for the encoded data on this
fixed input, not speed, memory efficiency, 7-Zip, holdout, or broad compatibility.

Prunlet direct-CMD cleanup deleted only the registered work tree
`<作業フォルダー>\UnLhaRe\goal-restore-20261019\run-50463dc66c2e45bfb2db341dd3777d87`. The 89-item preview
and delete receipts verified exactly 74 files / 5,453,097 B, no warnings, and no reparse points;
the persisted Prunlet operation was `febe40864ef24397917b0834e93eb8f4`. Its purge preview and result
verified 5,453,097 B purged with no warnings. The retained task recovery ZIP was independently
verified against all 74 live-file hashes before deletion and still contains the CLI archive and E2E
report. `Finalize-KhcStorageRun` recorded `State=complete`, `BeforeBytes=5,453,097`, `AfterBytes=0`;
`Test-KhcStorageCompletedReceipts` passed with four receipts. The work directory is absent, no
target process remains, and there are no pending lifecycle runs.

| Retained artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| `spatial-mdl-e2e.json` in recovery ZIP | 7,162 | `0e40433b9d34ec9e1768a5feb5994bdb399d0ece03d0912b5326961387ad65cb` |
| `recovery.zip` | 746,805 | `01213acee59e953bdbe8a04bf27e13ef1719a9f9f811d33afc11b1ccda5370ca` |
| `recovery.json` | 21,644 | `08ec71a08f6879245d8dc7163c218f2c0ef85d025e42232442c2ca961904261d` |
| `complete.json` | 1,592 | `ef163a411756bf0b475c99be72197bd796a11bb7f1d3d8a619b6fa30cd2b5247` |
| `cleanup-request.json` | 22,668 | `817cec988e5b8b3df263af50b103058eb768c9cd41e3ca2471fbf21e181225bd` |
| `cleanup/delete-preview.json` | 18,942 | `3e4ca99c5ad967e06c50945575a1f06b86c6a57909a29ac3169a9205fb762f15` |
| `cleanup/delete-result.json` | 29,258 | `409755d1a45267c261ba6774b971960a614a054317f1880613786bbe40b866c6` |
| `cleanup/purge-preview.json` | 29,659 | `5fe9dbbe41439c6a4b7b88a3cee7c7cbc3480b9ade3d5faed15954d54cf49a2a` |
| `cleanup/purge-result.json` | 29,296 | `07050cff4f3150b180e3af2d44302913e736826472755eee0ba5acc1b5a33b81` |

The Prunlet recovery folder retains its operation manifest/intent/result metadata, but the 74 backup
payload files were purged; the independent recovery ZIP above remains the restoration source. This
correctness E2E did not measure performance or change the status of any previously closed
benchmark/holdout condition.

## Count-only KCS1 candidate-size correctness E2E preregistration (2026-10-20)

This is a new source/binary condition after the count-only rANS candidate-size run above, not a
retry of that run. The `PortfolioTrial` KCS1 length evaluation now uses the same range state
transitions, output-limit decisions, and five final shifts as materialized encoding, while
skipping payload allocation/writes and frame packing. Before one registered correctness E2E, the
following inputs and outputs are fixed:

| Pin | Value |
| --- | --- |
| Rust source manifest (`src/**/*.rs`, 37 files) | `2c0335cea83661ff72c81875c01d67bd4737fa2273117e8a5ac7dc9dbb9f3a21` |
| KHC source manifest (`src/khc/**/*.rs`, 27 files) | `16e8cd800b8696b92d2dc8e928cde73262779845157717d90a94075a650a1088` |
| `src/khc/block/multi_range.rs` | 7,032 B, `ab91dfe1ca90a383eaf5556f636f2ae3667123936c34c731a2ce767ef899f6c8` |
| `src/khc/spatial.rs` | 17,392 B, `8efc560b9954d96cb664645ec0aa97e3d97d92fc60b2f8aaf74ca2fe8a0f0185` |
| `src/khc/mod.rs` | 36,025 B, `f4823c30f25c929ec0bde978ad4eefc3bdb35a8a440d3f1bff4ae5ffab3fbd0a` |
| `Cargo.toml` / `Cargo.lock` | 1,414 / 30,555 B, `3b47e50b8e543a5af82617bee4d4bd48ec20fc795a333ba50cbc9e439e0c2fac` / `d8dab69b03805b559440c186ed04c2d0d0ee57eba922306cfa6827bf79985554` |
| Release x64 MSVC `unlhare-cli.exe` | 2,581,504 B, `e1776bc7ca53109b77fa9f9f4215a2213f0fae28e7added9d6b9c1fdd9c77b7d` |
| Release x64 MSVC `khc_spatial_mdl_e2e.exe` | 1,671,168 B, `bfec6d9b50e9036efe760df642b03d4063b6f52ba82d94699e61a0f616559fa8` |
| Fixed input recovery ZIP | `<作業フォルダー>\TaskArtifacts\UnLhaRe\storage-lifecycle\runs\8a849a3267954242bcd8424b93526176\recovery.zip`, 769,634 B, SHA-256 `882e7108870c3de5d20de6e87ffc89f390c5d34630930aef73baed9171557f75` |
| Fixed ZIP member | `input/ptt5`, 513,216 B, SHA-256 `0ec3a75089bb52342813496b17e51377bc9eba3cb519a444d67025354841d650` |
| Runner limits | 8 MiB / 96 entries / 300 seconds outer; 240 seconds per child |

The Rust source manifests use sorted UTF-8 relative paths under `src` and `src/khc`, respectively,
with tab-separated path, byte length, and lowercase SHA-256 records. The locked/offline Release
build and `rustfmt --check --edition 2024` passed. The first eight-target Release-test invocation
hit the Cargo wrapper's 180-second deadline during compilation and reported no test cases; it is
not counted as a pass. A subsequent run of the seven already-built targets (`khc_normal`,
`khc_adversarial`, `khc_block_normal`, `khc_block_adversarial`, `khc_hybrid`,
`khc_model_boundary`, and `khc_state_safety`) passed all nine tests with wrapper exit 0.

The sole acceptance is the existing `spatial-mdl-e2e.ps1` run with these exact binaries and the
fixed input, requiring every existing child check and exact restored hashes. The CLI archive data
suffix at offset 89 must remain 39,962 B with SHA-256
`5f66e0e3552647ce66ce6020dca6c1abae889e9bfcd3ef5b94669d5fb4364977`, matching the preregistered
prior bytes. This E2E is correctness evidence only: it does not measure speed/memory, compare with
7-Zip, or establish representative/holdout superiority. Permit one registration; stop on
registration, E2E, cleanup, or suffix-comparison failure without retrying this unchanged
source/input condition.

### Completed count-only KCS1 candidate-size correctness E2E and cleanup (2026-10-20)

The single registered run `f7fc285670c848a49a16ee426aba380a` passed all 34 expected child checks:
14 successful commands and 20 intentional invalid/no-replace rejections. The API created revision 10
with eight frames, rejected nine malformed archives, read revisions 1–9, and exercised the memory
reservation guard. The CLI created, listed, tested, and extracted a two-file archive totaling
513,225 B; restored hashes matched the pinned inputs (`ptt5.bin`: 513,216 B,
`0ec3a75089bb52342813496b17e51377bc9eba3cb519a444d67025354841d650`; `short.bin`: 9 B,
`073f8a6663fc49fd74e1e6dfd4d18d0bffb6e9a2af848e7adfbd4a567fbf732c`).

The CLI archive was 40,051 B, SHA-256
`f10aef46aff210ce5918da841fa4414e6b60cd66ac603ebd74164911621f55ba`. Its 39,962 data bytes at
offset 89 exactly matched the preregistered baseline SHA-256
`5f66e0e3552647ce66ce6020dca6c1abae889e9bfcd3ef5b94669d5fb4364977`. The report was 7,162 B,
SHA-256 `e259367714a3e87b4645316e13382f9d7b6d2db364dae18129d380e8ec7ad270`; a second verification
read both values from the retained recovery ZIP. As before, the timestamp-sensitive archive hash
and fixed-input suffix equality do not establish speed, memory efficiency, 7-Zip superiority, or
holdout performance.

The registered work tree was `<作業フォルダー>\UnLhaRe\goal-restore-20261019\run-87773170ca784bbba2066ff208269dac`.
Its recovery ZIP and manifest were independently checked against all 74 files before cleanup. The
first direct-CMD delete operation `12491472ca174f358abde0fbab1a6dc8` was used to restore the exact
verified tree after its first stdout was not captured; no build or E2E was repeated. A second
direct-CMD delete operation `8d081ae262d449f4956a221824960164` saved genuine delete receipts to the
registered TaskArtifacts paths. Both operation purge previews contained 74 `would_purge` files and
15 `not_backed_up` directories, with zero warnings; both applied purges removed exactly 74 backup
files / 5,453,097 B. Prunlet recovery metadata remains, while the independent TaskArtifacts ZIP
remains the restoration source. The registered run finalized with `State=complete`,
`BeforeBytes=5,453,097`, `AfterBytes=0`; `Test-KhcStorageCompletedReceipts` passed with four primary
receipts. The work tree and related processes are absent.

| Retained artifact (under `<作業フォルダー>\TaskArtifacts\UnLhaRe\goal-restore-20261019\storage-lifecycle\runs\f7fc285670c848a49a16ee426aba380a`) | Bytes | SHA-256 |
| --- | ---: | --- |
| `spatial-mdl-e2e.json` in recovery ZIP | 7,162 | `e259367714a3e87b4645316e13382f9d7b6d2db364dae18129d380e8ec7ad270` |
| `cli-revision-10.khc` in recovery ZIP | 40,051 | `f10aef46aff210ce5918da841fa4414e6b60cd66ac603ebd74164911621f55ba` |
| `recovery.zip` | 746,809 | `faa27ce5f09f36631bc8e64286943a7fdcffcc8680307906b293cd05ee453ca7` |
| `recovery.json` | 21,644 | `ff74d0b6bde4be984230162e5b63a84cadb5a778438ef3288cbe18589f94e730` |
| `cleanup-request.json` | 22,668 | `fe73d6c647733eb145c478593547d1b27ceb5d5a60f12ffb70952c2f25828212` |
| `complete.json` | 1,592 | `e404265c77e0bf9c85417c343b5068f5f148f7305b89c7718d65cc404cef1908` |
| `cleanup/delete-preview.json` | 18,943 | `4ee73865880d9f5e7af4c1d3aa8d78554698aca505bae73ec5d7a248a5912f53` |
| `cleanup/delete-result.json` | 29,259 | `9109967a187849aff4dcf02d6e8e9d9bd2edd2fa64249fe39b575a896224e206` |
| `cleanup/purge-preview.json` | 29,660 | `ae31c8a6c952a45a19c3413625ec64a64aa1fac410be384eefeba046822a95e7` |
| `cleanup/purge-result.json` | 29,297 | `ad21659c112a3a5e2745ff42a9be8eb0c924c4609992da09b6a07774513f5f1d` |
| `cleanup/duplicate-operation-purge-preview.json` | 29,660 | `98a2b331329c726d7cdb111c216fcb6394d0abe313f693d6c7f913f637014d7e` |
| `cleanup/duplicate-operation-purge-result.json` | 29,297 | `672e2d64e76f4167b658edb7e02ab7610fc7aadc35ad28854829546d31f37111` |

## Canterbury KCS1 count-only candidate-length product screen preregistration (2026-10-20)

This is a new source condition for the KCS1 count-only candidate-length optimization, not a retry of
the earlier Canterbury schedule-replay screen that stopped at its CPU gate before the first timed
command. Canterbury has already been used for development and remains training/tuning data only;
this screen cannot count as an independent holdout or establish general 7-Zip superiority. The
comparison is limited to the fixed 11-file Canterbury set and the source/runtime pins below.

The immutable campaign will use ID `1473558eb3cd40b584259586378602db`, marker
`<作業フォルダー>\TaskArtifacts\UnLhaRe\goal-restore-20261019\canterbury-development-kcs1-count-length-20261020\campaign-start.json`,
4,475 B with SHA-256 `9c47f2eff1217a68e8d036f026d5b1679601f1f1c5f909695fbb1e563bbc45d5`,
and the fixed UTC window `2026-10-20T01:30:00.0000000Z` through `2026-10-20T02:00:00.0000000Z`.
The marker must pin these exact values and the final worker, runner, lifecycle and aggregator hashes;
no registration is allowed until its bytes/SHA, all source/tool pins, input validation, resource
budget, pending-run/process checks and the external CPU gate have passed.

| Pin | Fixed value |
| --- | --- |
| Recovery ZIP | `<作業フォルダー>\TaskArtifacts\UnLhaRe\storage-lifecycle\runs\5e93ed1e99ca4f5ab29d490db421e50b\recovery.zip`, 8,765,120 B, SHA-256 `b74644fac5f89251b15a68db6b2a3bce1bd508c12f0f685a61cd5c96ae1540bb` |
| Selected input | Prefix `pipeline-e2e/canterbury/`; 11 files / 2,810,784 B; file-set manifest SHA-256 `bb63b0d70713c9aefa681347eaf99fb891d59f45923e009ad0deadc9ec9fc438` |
| Rust source (`src/**/*.rs`, 37 files) | SHA-256 `2c0335cea83661ff72c81875c01d67bd4737fa2273117e8a5ac7dc9dbb9f3a21` |
| KHC source (`src/khc/**/*.rs`, 27 files) | SHA-256 `16e8cd800b8696b92d2dc8e928cde73262779845157717d90a94075a650a1088` |
| Release x64 MSVC CLI | 2,581,504 B, SHA-256 `e1776bc7ca53109b77fa9f9f4215a2213f0fae28e7added9d6b9c1fdd9c77b7d` |
| 7-Zip | 26.04 x64, `C:\Program Files\7-Zip\7z.exe`, SHA-256 `95fff19b73eff77c87c0d7bd32822e43fb90dd2932459f962eb532d8dfb6ba53` |
| Product-screen worker | SHA-256 `c0feb17ab14ed59d0333b9e3615817cfb9c37f0cd2b18c66e7224f693c31c034` |
| Registration runner | SHA-256 `662714b836fae361a3c4561d86ee4ef97b330b8e7d93741b91aaf45e4a3893c9` |
| Storage lifecycle | SHA-256 `a51c4c36d598dcfe5adff911845476f73ec3ba82a146038d70599bccb11414c4` |
| Aggregator | SHA-256 `68fe1e903bec601d101c7be67a8534b7e54dc6e50f49506ba47571bdb1bf0319` |
| Cargo manifest / lock | SHA-256 `3b47e50b8e543a5af82617bee4d4bd48ec20fc795a333ba50cbc9e439e0c2fac` / `d8dab69b03805b559440c186ed04c2d0d0ee57eba922306cfa6827bf79985554` |
| Disk-budget script | SHA-256 `506e4c68dc05734bc1a0c02bac6f81d4677e0bcffd9b9fa2b7bd67d53319bdcd` |

Run exactly 20 serial one-sample registrations through `run-storage-experiment.ps1`: rounds 0–9,
both `portfolio-trial` and `7zip`; round 0 is warmup, rounds 1–9 are measured, and starting order
alternates by round parity. Each registration uses the fixed profile, recovery ZIP, Release CLI,
7-Zip path, round, strategy and immutable marker SHA. The candidate uses one create thread and four
extract workers. 7-Zip creates solid 7z/LZMA2 level 9 with a 64 MiB dictionary and one thread
(`-t7z -mx=9 -m0=lzma2:d=64m -mmt=1 -ms=on -mqs=off -mtm=off -mtc=off -mta=off`); extraction
uses `x -mmt=4`. The worker restores each fixed ZIP member's `LastWriteTime` after extraction
because KHC records input modification times in its manifest; this makes repeated candidate bytes
deterministic. 7-Zip's `-mtm=off` omits those optional file times, so its size baseline is
conservative against KHC's fixed timestamp-metadata cost and is not a same-metadata comparison.
Metadata-only inspection of the pinned recovery ZIP confirmed all 11 selected entries have the
same fixed UTC `LastWriteTime`, `2026-10-16T05:10:36Z`.

The pre-registered pass criterion is candidate complete-archive size at most 95% of 7-Zip and both
candidate create and extract medians no slower than 7-Zip. The aggregator also requires stable full
archive SHA-256 per strategy, exact member restores/hashes, all 20 lifecycle completion/cleanup
receipts, no CPU/memory/time/entry-cap failure, and total campaign elapsed time at most 1,800 s.
Each run is limited to 32 MiB / 512 entries / 300 s; each timed child command is limited to 60 s and
160 MiB. The external start CPU gate and each timed-child CPU gate take five 1-second samples, all
at most 15%; stop at the first over-cap sample or any other failure, with no retry, relaxed gate,
deadline extension or alternate output root. Complete Prunlet cleanup for each registered run
before starting the next. No timed run has started and no performance result is available at this
preregistration point.

#### Count-only KCS1 Canterbury screen stopped before registration (2026-10-20)

The immutable marker and all input, source, Release CLI, 7-Zip, worker, runner, lifecycle,
aggregator and disk-budget pins matched inside the fixed window. Input validation confirmed the
11-file / 2,810,784-byte member set and its hashes. The read-only storage reservation passed at
`2026-10-20T01:32:11.1603059Z`; there were no pending lifecycle runs, related processes or
reparse-point hits. Total storage was 4,279,678,163 / 32,212,254,720 B, external regular storage
322,381,606 / 2,147,483,648 B, Cargo 3,954,966,764 / 6,442,450,944 B, lifecycle 193,494,233 /
1,073,741,824 B, and free D-drive space 507,170,324,480 B.

The external `_Total` CPU gate began at `2026-10-20T01:32:28.0786833Z` and stopped at its first
sample, `27.0%` at `2026-10-20T01:32:32.1529155Z`, above the fixed 15% limit. Stop before
registration with no retry. Registration count, run directories, timed candidate/7-Zip commands
and performance measurements are all zero. Input payload hashing occurred only for the pinned
input validation; no candidate or 7-Zip performance evaluation occurred. This is an environmental
pre-registration stop, not a codec no-go or performance result. The fixed condition is closed;
do not use the remainder of the window or retry it unchanged.

Retained stop record:
`<作業フォルダー>\TaskArtifacts\UnLhaRe\goal-restore-20261019\canterbury-development-kcs1-count-length-20261020\pre-registration-stop.json`,
2,120 B, SHA-256 `49f321cc8123c74987dde4cf634d00ae6dd467f13f7554e92314021d63a3df49`.

### NICT KCS1 count-length holdout preregistration (2026-10-20)

This is a new candidate-version profile, not a continuation or rebase of the earlier NICT campaign.
It uses the existing retained NICT input archive and metadata without copying them. The fixed corpus
has 195 files (one source family), 5,236,133 uncompressed bytes, and a 5,257,215-byte input ZIP
(SHA-256 `aee6335bc9f43f35e5c29c3944cb8067eefed618578c02c8faac4ff4112c5ecd`); its ordinal file-set
manifest is pinned as `cad92e76db4142c15c32b924f8906320a38fff42638d1cdc69e5a9ed157b66f5`. Existing
provenance remains in the retained input metadata. This is holdout-only: development, training and
tuning are all false. Its single source family cannot establish broad superiority by itself.

The immutable campaign marker is
`<作業フォルダー>\TaskArtifacts\UnLhaRe\goal-restore-20261019\nict-wiki-kcs1-count-length-holdout-20261020-v2\campaign-start.json`
(5,012 B, SHA-256 `136ee134727ced18f6c24314349180b1f87c3d3af9579b4e1b05d130550b151e`, campaign
`5f4eae64b259422bb79f00055c789ace`). Its fixed window is `2026-10-20T02:30:00Z`–
`2026-10-20T03:00:00Z`. The profile/source condition is
`NictWikiCorpusKcs1CountLengthHoldout20261020`; the separate run/report root is the same v2 directory.
The marker and fixed input metadata passed `Assert-KhcNictKcs1HoldoutCampaign` at
`2026-10-20T01:52:25Z`; that is preregistration validation only, not campaign admission or an evaluation.

The marker pins the 37-file Rust source manifest (`2c0335cea83661ff72c81875c01d67bd4737fa2273117e8a5ac7dc9dbb9f3a21`),
27-file KHC source manifest (`16e8cd800b8696b92d2dc8e928cde73262779845157717d90a94075a650a1088`), Release CLI
(2,581,504 B, SHA-256 `e1776bc7ca53109b77fa9f9f4215a2213f0fae28e7added9d6b9c1fdd9c77b7d`), 7-Zip 26.04
(`95fff19b73eff77c87c0d7bd32822e43fb90dd2932459f962eb532d8dfb6ba53`), worker
(`bfb9e403a8cef5e4e4d44827e5dc1c0a9decc05ce7c74c3135ab10aeb07ab8c3`), runner
(`24c340ee31a3813e54e239ef0948cdd3d3f38e86880910a30b06daf446e45bf7`), lifecycle
(`86543471511d1c1981feb303d92b0641bc4a8a79ce1a57782e47e1d936cfa339`), aggregator
(`70b1dae0b82fa649310366fbd71eaf05d977a4b1167ebebb06e6fa08e80e9678`), and disk-budget manifest
(`506e4c68dc05734bc1a0c02bac6f81d4677e0bcffd9b9fa2b7bd67d53319bdcd`).

If admitted by a fresh in-window preflight and five-point external `_Total` CPU gate, the fixed
comparison is 20 serial one-sample runs: round 0 warms both strategies; rounds 1–9 are measured with
the starting strategy alternating by round parity. KHC uses one create thread and four extract
workers. The baseline is 7-Zip 26.04 solid 7z/LZMA2 level 9, 64 MiB dictionary, one create thread and
four extract threads (`-mtm=off -mtc=off -mta=off`). A pass requires candidate complete-archive size
at most 95% of 7-Zip and both candidate create/extract medians no slower than 7-Zip. Fixed bounds are
32 MiB and 512 entries per run, 300 seconds per run, 60 seconds and 160 MiB per child, and 1,800
seconds total. Every five-point CPU gate is capped at 15%; stop at the first failed or missing sample,
with no retry, window shift, or threshold relaxation. The five-point gate must be repeated at campaign
start and before every timed command. The 7-Zip timestamp options are disabled, so KHC bears timestamp
metadata overhead; this remains a conservative size comparison, not a same-metadata comparison.

An earlier immutable marker attempt in the old output directory was closed before registration because
it omitted the validator-required top-level `input_entry_prefix` (the value existed only under
`source_provenance`). The validator rejected it before input ZIP hash verification; no payload was
evaluated, and registration/timed commands were zero. Preserve that marker
(`nict-wiki-kcs1-count-length-holdout-20261020\campaign-start.json`, 4,988 B, SHA-256
`607d3e1fecd02ff6ef26c6d492e8a79547225508815725036373cbf8ab23865b`, campaign
`9a8305553f634a79b8b38316f66194fe`) and its stop receipt
(`pre-registration-stop.json`, 1,284 B, SHA-256
`b52ef2c9dea894d638bd032d3bacd284846deffb31cc7b5839c63bfabdf503cf`) unchanged. The v2 marker has
the required field, a new campaign ID and a distinct output path/window. Neither marker authorizes
starting before its fixed window or bypassing the fresh CPU gate.

#### NICT KCS1 holdout stopped before registration at external CPU gate (2026-10-20)

The fixed window opened at `2026-10-20T02:30:00Z`. The fresh marker/open-window validator,
provenance metadata pins, source/script/tool pins, 290 MiB read-only storage reservation, pending-run,
process, reparse-path and output-root checks all passed at `2026-10-20T02:30:18.5909031Z`. At that
point total usage was 4,279,691,567 B, external regular usage 322,395,010 B, Cargo 3,954,966,764 B,
lifecycle 193,494,233 B, and free D: space 506,696,605,696 B.

The external `_Total` CPU gate began at `2026-10-20T02:30:29.6886575Z`. Its first sample was
16.9474% at `2026-10-20T02:30:32.5890533Z`, above the fixed 15% limit, so collection stopped there;
the remaining four samples were not taken. Registration, campaign run directories, timed candidate/
7-Zip commands and performance measurements are all zero. Preflight verified the pinned provenance
metadata but did not hash the input ZIP or any member payload; the runner's input validation was not
reached. This is an environmental pre-registration stop, not a codec no-go or performance result. The
fixed condition is closed; do not retry it unchanged or reuse the remainder of its window.

Retained stop record:
`<作業フォルダー>\TaskArtifacts\UnLhaRe\goal-restore-20261019\nict-wiki-kcs1-count-length-holdout-20261020-v2\pre-registration-stop.json`
(2,864 B, SHA-256 `9f0caad00ee6d2ef707726742af31202add2fd2f182ae8bd359194023df071a7`).


### UCI Dry Bean dedicated one-family holdout profile integration (2026-10-20)

UciDryBeanHoldout20261020 is a separate conditional one-family screen. Development,
training, tuning, feature selection and threshold changes are forbidden. Its category
contribution is zero: no addition to the final 13-category/three-family aggregate, broad
superiority or final-GOAL claim. UciTabularDevelopment20261020 remains hard-disabled and
metadata-only. NICT and Canterbury conditions are not reopened.

Source/rights authority:
<作業フォルダー>\TaskArtifacts\UnLhaRe\goal-restore-20261019\uci-dry-bean-holdout-20261020\acquisition-lock.md,
SHA-256 4d1b0d8cbcec51cd9feb7107566865cc37bce39dee605f67dfdc847d78cb7393.
UCI Dry Bean ID 602, dataset DOI 10.24432/C50S4B, M. Koklu and Ilker Ali Özkan (2020),
is CC BY 4.0 with appropriate credit. Preserve that attribution and article DOI
10.1016/j.compag.2020.105507. The UCI page explicitly grants these terms; only the .txt
rights/provenance sidecar was read. No LICENSE/NOTICE/COPYING exists in the distribution.
Official source URLs and rights findings are frozen in profile Provenance. This integration
relies on the acquisition lock; it did not independently browse or inspect payload.

All source paths below are relative to the lock directory, outside its separate campaign
output directory and outside transient lifecycle run/cleanup roots.

| Identity | Bytes | SHA-256 |
| --- | ---: | --- |
| Official dry-bean-dataset.zip | 4,738,776 | 0a64eff5be87f48c3dbbfc0a12a56c5d5b5167ef8e61cd45d69b3e7c7130c06f |
| Official member DryBeanDataset/Dry_Bean_Dataset.arff | 3,813,205 | b2a4a76a2aedfb8ed415adfc1bfc70b5f202cb00cb72e500766e364c14834014 |
| Stored runner wrapper dry-bean-input.zip | 3,813,357 | 8052ba1666b0254c3b8911289d72d0cc205484cce37eb784cab3c14fdeff1221 |

The wrapper has exactly input/Dry_Bean_Dataset.arff, unchanged bytes, stored method,
ZIP DOS local timestamp 1980-01-01 00:00:00. EntryPrefix=input/ yields relative entry
Dry_Bean_Dataset.arff. Canonical UTF-8 name<TAB>bytes<TAB>lowercase-sha256 has no final LF;
manifest SHA-256 is 172896a2dfa74a8e8dad154c92bf5c12ab8ddf62e89d5d96c5e5f5c1769f7d83.
Do not display, parse, normalize, convert or reserialize the ARFF.

Assert-KhcDryBeanMetadataGate validates immutable marker SHA, exact provenance schema,
acquisition/rights-lock SHA and admission fields before wrapper/member access. The dedicated
Assert-KhcDryBeanHoldoutCampaign uses the common fixed screen contract and validates the
original source ZIP, candidate/tools/scripts and input identities. Runner, worker, aggregator
and abandoned-run recovery explicitly select it, without NICT/Canterbury validator/data-path
dispatch. Immutable marker `campaign/campaign-start.json` is 4,847 B,
SHA-256 `aeb22cb2ec810b9ca1ba8a09bec68c1ba75cbbede4ee2befdc848e2cd37cc284`,
campaign ID `b4b82fe9e40c4c4ab0d659752a04cbb3`; its only fixed execution window is
2026-10-20 03:30:00–04:00:00 UTC. Output directory:
<作業フォルダー>\TaskArtifacts\UnLhaRe\goal-restore-20261019\uci-dry-bean-holdout-20261020\campaign.
No registration, worker, or codec command has started; any failed admission gate closes
this exact Dry Bean condition without retry or window change.

Besides common campaign fields, a marker requires source_condition=UciDryBeanHoldout20261020,
source_provenance exactly equal to profile Provenance, input_entry_prefix=input/, one exact
input_entries record, single_family_screen_only=true, aggregate_category_count=0 and the
KHC manifest pin. Roles: input_role=holdout-only, holdout_only=true, development_only=false,
training_allowed=false, tuning_allowed=false; general_superiority_claimed=false and
final_goal_achieved=false. Run reports and aggregate retain these fields; mismatches fail.
Final decision labels are one-family-holdout-screen-pass / one-family-holdout-screen-no-go.

Frozen recipe: 20 serial single-sample runs / 10 pairs; pair 0 warmup, pairs 1–9 measured;
alternating starting strategy by parity. KHC create 1 thread / extract 4 workers.
7-Zip 26.04 solid 7z/LZMA2: -mx=9 -m0=lzma2:d=64m -mmt=1 -ms=on -mqs=off -mtm=off
-mtc=off -mta=off; extraction x -mmt=4. Complete archive <=95% of 7-Zip; KHC measured
create/extract medians each <=7-Zip. Exact raw restore and deterministic complete-archive
SHA across all 10 samples per strategy are mandatory. Caps: 32 MiB / 512 entries / 300s
per run, 60s / 160 MiB per command, 1800s immutable campaign. Require five fresh external
CPU samples <=15% before registration and five before every timed command. Stop at first
failed/missing sample; no retry, window rebase or reuse of a closed condition.

Rust source manifest: 2c0335cea83661ff72c81875c01d67bd4737fa2273117e8a5ac7dc9dbb9f3a21.
KHC source manifest: 16e8cd800b8696b92d2dc8e928cde73262779845157717d90a94075a650a1088.
CLI: 2,581,504 B, SHA-256 e1776bc7ca53109b77fa9f9f4215a2213f0fae28e7added9d6b9c1fdd9c77b7d.
7-Zip 26.04: SHA-256 95fff19b73eff77c87c0d7bd32822e43fb90dd2932459f962eb532d8dfb6ba53.

| Script | Bytes | SHA-256 |
| --- | ---: | --- |
| storage-lifecycle.psm1 | 165,499 | dd726cbd8d458a3d16dc03b40cfd104fd6ec6fc3ff115f1031a7f0f5931434ee |
| run-storage-experiment.ps1 | 42,992 | 31f4de985e0e12cc018368839766c90441ee7f86f83fb26c34727b4e9d2854c3 |
| portfolio-7zip-product-screen.ps1 | 45,684 | 9c5dc05340635d5f436dbf2b989d089eda7a7eac5e2f0288e26f992e142a90f3 |
| aggregate-portfolio-7zip-product-screen.ps1 | 56,668 | ef82289440fa8afc0d5d16a8e08e1a93a096eebab42787fbb4bbb9818f1c231f |

The immutable campaign marker exists at `campaign/campaign-start.json` (4,847 B,
SHA-256 `aeb22cb2ec810b9ca1ba8a09bec68c1ba75cbbede4ee2befdc848e2cd37cc284`;
campaign `b4b82fe9e40c4c4ab0d659752a04cbb3`, fixed window 03:30–04:00 UTC).
At 03:30:23.9118654 UTC its open-window marker validation passed; all 115 lifecycle
records were complete, no related process or reparse path was found, and the 290 MiB
reserve passed the fixed storage budgets. The external start CPU gate then stopped at
sample 3: 18% at `2026-10-20T03:30:38.5320346+00:00`, above the immutable 15% limit.
The exact condition is closed; do not retry, rebase the window or register a replacement.
No lifecycle run registration or run directory, worker/aggregator invocation, codec or
7-Zip command, build, timed command, member extraction/inspection or performance result
exists. The retained stop record is
`<作業フォルダー>\TaskArtifacts\UnLhaRe\goal-restore-20261019\uci-dry-bean-holdout-20261020\pre-registration-stop.json`
(1,753 B, SHA-256 `d7c878eaed02d39510642549cfd8a8177bb9d79506b6038045832f7227f34342`).
The four PowerShell Parser checks, literal-profile schema and canonical manifest checks
remain successful static evidence only; restoration, comparative performance and general
superiority are unverified. The old UCI development guard remains closed.

## Scheduled-frame single-seal correctness E2E preregistration (2026-10-20)

The KRS2/KRS3 materializing path now builds its private intermediate KRS1 frame without
its wire CRC. The existing final scheduled header seals the complete frame once. Ordinary
KRS1 packing still seals before return. Candidate lengths, tie order, raw CRC, payload,
format identifiers and memory gates are unchanged. Static call-path review found no
consumer of the intermediate wire CRC and no unsealed public return.

One correctness run is admitted through `run-storage-experiment.ps1` with the existing
`spatial-mdl-e2e.ps1`, 8 MiB / 96 entries / 300 seconds outer and 240 seconds per child.
The fixed ptt5 recovery ZIP is unchanged: 769,634 B, SHA-256
`882e7108870c3de5d20de6e87ffc89f390c5d34630930aef73baed9171557f75`, at
`<作業フォルダー>\TaskArtifacts\UnLhaRe\storage-lifecycle\runs\8a849a3267954242bcd8424b93526176\recovery.zip`.
Its `input/ptt5` member remains 513,216 B, SHA-256
`0ec3a75089bb52342813496b17e51377bc9eba3cb519a444d67025354841d650`.

| Pin | SHA-256 |
| --- | --- |
| Rust source manifest, 37 files | `3b87f833af8ccd1daadd1e2f0fbfe4b8974c5776726207936ed7339b362ab04f` |
| KHC source manifest, 27 files | `bda2fa7fa3978d786f5877640fc28daf1d440570766c33cd8b5cf2ed8db21326` |
| `src/khc/record.rs` | `c4e040035d6bcee9c559eff92553e139d576924e94212568ddf29013aabe1f0b` |
| Release CLI, 2,583,040 B | `b8aad706a50614efee9dcd1353e0132e7af030ab7e61357cf25b57bd7e5afbc7` |
| Release E2E example, 1,672,704 B | `1c9b7ae366560988c91e5e967d44fec6ca4913bfb8793f84d7128f62e6312193` |
| E2E worker | `099153c0493f6e8d1736f52cebdbf044c50baf64f0310c55f0bcdb0ab0177b8b` |
| Storage runner | `31f4de985e0e12cc018368839766c90441ee7f86f83fb26c34727b4e9d2854c3` |
| Lifecycle | `dd726cbd8d458a3d16dc03b40cfd104fd6ec6fc3ff115f1031a7f0f5931434ee` |

Acceptance requires all existing E2E checks and exact restored hashes. In addition, compare
all 24 `.khc` members against the previous count-only KCS1 run's verified recovery ZIP
`<作業フォルダー>\TaskArtifacts\UnLhaRe\goal-restore-20261019\storage-lifecycle\runs\f7fc285670c848a49a16ee426aba380a\recovery.zip`
(746,809 B, SHA-256 `faa27ce5f09f36631bc8e64286943a7fdcffcc8680307906b293cd05ee453ca7`).
For each archive, the exact data suffix starts at 32 plus its little-endian u32 manifest
length at offset 20. Sort member names ordinally and hash UTF-8 records of name, suffix
length and suffix SHA-256 separated by tabs and terminated by LF. The frozen 24-member
suffix-manifest SHA-256 is `57f34e63ea849913853d2487008121635d0a5416656101624a5f50fb6eb22b71`.
This covers ordinary KRS1, actual KRS2/KRS3 in accepted-all, fallback, and malformed frames
without treating changing file timestamps as codec changes. Any mismatch fails this run.

`rustfmt --check --edition 2024` passed. The compiler finished the locked/offline Release
build in 57.38 seconds, but its wrapper failed because `vctip.exe` survived the two-second
Job drain; the wrapper terminated the Job. A fresh process check found no relevant child.
The subsequent no-op freshness build passed the wrapper (Cargo 0.12 s, wrapper 0.99 s).
The initial wrapper failure is retained as a failure. This correctness run measures no
speed or memory improvement and reopens no closed performance/holdout condition.

### Completed scheduled-frame single-seal correctness E2E (2026-10-20)

Run `138e9e5ec2e04c6085a6e3ffefff700e` passed the registered worker, exit 0:
34 expected child outcomes (14 successes, 20 expected refusals), revision-10 API's
8 frames, 9 malformed-archive rejections, revision 1–9 reads, memory reservation guard,
and CLI exact restoration of 2 files / 513,225 B. No test source was added.

All 24 archived `.khc` data suffixes matched the frozen prior-output manifest exactly:
`57f34e63ea849913853d2487008121635d0a5416656101624a5f50fb6eb22b71`.
This includes actual KRS2 and KRS3 frames, ordinary KRS1, fallback and malformed archives.
The CLI archive is 40,051 B (full SHA-256
`26e4a91c2f3dd65f01a789c601fad401fb3053f777596b7823aa62af395b9373`);
its timestamps differ from the prior run while the complete data suffix is identical.

Retained evidence is at
`<作業フォルダー>\TaskArtifacts\UnLhaRe\goal-restore-20261019\storage-lifecycle\runs\138e9e5ec2e04c6085a6e3ffefff700e`:
`recovery.zip`, 746,804 B, SHA-256
`448f2c9fff97489fda72731c5eb7be7ea8db321b05fc8366f8acc5287881f696`;
`recovery.json`, SHA-256 `46cfdd09f45f4fe78af24d299057e5006a580fe4660b4e58656d5e541252f965`;
and archived `spatial-mdl-e2e.json`, 7,162 B, SHA-256
`a24c2df265c110a1ff1e4f22cc912dd6bc02e116929c6868216717ba542b8b10`.
The ZIP contains the exact development inputs, output archives and child outcomes; use
the manifest to restore and recheck them. Retain it for regression reproduction until
the single-seal candidate is superseded and equivalent evidence is preserved elsewhere.

Direct-CMD Prunlet operation `33dbf1f035124be68e4aa1ced5607495` verified and removed the
89-item tree (74 files / 5,453,097 B and 15 directories), purged its duplicate backup
payload after the recovery ZIP was verified, and finalized with `BeforeBytes=5453097`,
`AfterBytes=0`, state `complete`. Only Prunlet operation metadata and the independent
recovery evidence remain. This demonstrates byte identity and finite correctness;
comparative speed, peak memory and the GOAL's 7-Zip superiority gate remain unverified.

### Final single-seal lint cleanup correctness preregistration (2026-10-20)

The additional Release Clippy check exposed three existing warnings: the last optional
mutable reference was unnecessarily reborrowed, prepared-model arguments exceeded seven,
and a validated three-byte model extent used `chunks_exact`. The final source consumes
the last reference, groups preparation with its initial models, and uses `as_chunks::<3>`
after the same exact-length check. Review found no new allocation or state/order change.
`rustfmt --check` and Release Clippy for lib/CLI/E2E with `-D warnings` now pass.

Before one final E2E, fix Rust/KHC source manifests to
`4011127d02a1d0f97fb37937e9cb8159fa792bddc0ae2ab0185ab2a2577f1350` /
`d3871acfe3aa4e398b35e6f0a575a5d5099630cffa29b323ac5875180e1f79b6`;
CLI 2,583,552 B SHA-256 `453b03419aa5d22a0702fba32ecb30187637044c196163039923ff5962d9b6dd`;
E2E 1,673,216 B SHA-256 `a1348d28f258d3b0f73cad3174421e24bcaf046767a120266c73ead509d53979`.
Use the same fixed ptt5 ZIP, unchanged runner/worker/lifecycle, 8 MiB / 96 entries /
300 seconds and 240-second children, all existing assertions, and the same frozen
24-suffix manifest `57f34e63ea849913853d2487008121635d0a5416656101624a5f50fb6eb22b71`.
The latest compiler run finished in 54.27 s but again failed the Job-drain check on
`vctip.exe`; the Job was terminated and no child remained. The following no-op freshness
build passed (Cargo 0.22 s / wrapper 0.98 s). Neither failed wrapper is counted as a pass.

### Completed final single-seal lint cleanup E2E (2026-10-20)

Final run `7ca5b9931bcf4b9d9861b0d71f0130ab` passed all 34 expected outcomes
(14 success / 20 expected refusals) and the same exact 24-suffix manifest
`57f34e63ea849913853d2487008121635d0a5416656101624a5f50fb6eb22b71`.
Thus the lint-cleaned final source preserves ordinary KRS1, actual KRS2/KRS3, fallback
and malformed-output bytes for this fixed finite development suite.

The final D: TaskArtifacts lifecycle run directory retains `recovery.zip`, 746,800 B,
SHA-256 `9c2fd73251bb6dcf6f22552e54ee6c24cf2f716b05cbe5c3caf21b7cffb7ddab`;
`recovery.json`, SHA-256 `dd5eb0b36c6d465e85ed623f1cbbc961b9845c8e3d00e39b137ad7b8b4544d18`;
and archived `spatial-mdl-e2e.json`, 7,162 B, SHA-256
`c43e52984549f05dc9e623fde7a389b55acb5becc53526c282eb718f64304d95`.
Use the same restoration recipe and retention condition as the preceding run.
Prunlet operation `e8589d58eb624b3b937d7efe7a74a562` removed the final 5,453,097 B
temporary tree, purged its redundant backup payload, and finalized state `complete`,
`AfterBytes=0`. Clippy and rustfmt pass; fresh compilation still exhibits the separately
recorded MSVC telemetry Job-drain failure. No comparative timing was performed.

## Single-seal KRS2 development speed-frontier preregistration (2026-10-20)

This is a new `SingleSeal20261020` source condition for explicit `record-fast-trial`,
where actual KRS2 frame materialization traverses the single-seal implementation above.
It is not a reopening of a closed Portfolio campaign merely because a source hash changed.
All five `record-fast-trial` samples must contain exactly one actual KRS2 frame; fallback
fails this condition. The sole immutable marker is
`<作業フォルダー>\TaskArtifacts\UnLhaRe\goal-restore-20261019\krs2-single-seal-frontier-20261020\campaign-start.json`,
2,390 B, SHA-256 `9a3109f0b11f5f35b627982f494bd09888d3f070e47c17ee8329ea15d76aab77`,
campaign `a424e51c266b492193c354ca6a40379b`, fixed UTC window
`2026-10-20T04:45:00Z`–`2026-10-20T05:00:00Z`. It is single-use, development-only,
not holdout, general superiority, or final GOAL evidence. No window change or retry is allowed.

Rust/KHC source manifests and the Release CLI remain the final lint-cleaned pins above:
`4011127d02a1d0f97fb37937e9cb8159fa792bddc0ae2ab0185ab2a2577f1350` /
`d3871acfe3aa4e398b35e6f0a575a5d5099630cffa29b323ac5875180e1f79b6` and
`453b03419aa5d22a0702fba32ecb30187637044c196163039923ff5962d9b6dd`.
Input is only the unchanged pinned recovery ZIP `882e7108...1557f75` and complete
`input/ptt5` member, 513,216 B, SHA-256
`0ec3a75089bb52342813496b17e51377bc9eba3cb519a444d67025354841d650`.
The full ZIP path and digest are frozen in the immutable marker and earlier E2E preregistration.
No new input or holdout acquisition is part of this screen.

Use the registered `record-fast-7zip-screen.ps1 -SpeedFrontierStudy` with this closed
source-condition selector. The legacy selector retains its historical pins. Compare
BinaryAdaptive and KRS2 with all five 7-Zip 26.04 LZMA2 settings `-mx=1,3,5,7,9`,
`-m0=lzma2:d=64m -mmt=1 -ms=on -mqs=off`, timestamp metadata disabled. Disclose all
actual methods/dictionaries, full archive bytes, encode/extract process-start-and-I/O-inclusive
wall times and maximum OS working-set/pagefile peaks. KHC revision 2/6 extraction is serial;
this CLI has no thread argument for KHC. KHC timestamp metadata remains in its full archive
while 7-Zip's is disabled, a conservative fee for KHC rather than equal metadata content.

Run seven strategies in five rounds with the existing round-dependent rotation. Warmup
count is zero, and five rounds do not balance all seven order positions; these are explicit
limits of this finite local screen. Every archive must be deterministic within strategy,
pass its native integrity test, and restore the complete input bytes/hash. No data-dependent
input selection or changes to the candidate are permitted after first execution.

The candidate's full archive must be no larger than the fastest combined-median 7-Zip
profile among the five whose archives are at least as large as KRS2. KRS2 encode and extract
medians must each be at least 5% faster than that baseline, with no higher maximum working-set
or pagefile peak for either direction, and no profile among all five may dominate it on
size, both time medians, and both peak-memory measures. Missing eligible baseline, missing
counter, nondeterminism, restore failure or any budget/gate failure is not a pass.
Completion status and the mechanical `frontier_decision.screen_result` must be distinguished.
This does not estimate the CRC change's isolated speed contribution without an old-binary ablation.

Admission requires fresh pins/plain paths, no pending run or relevant process, fixed storage
budgets and a fresh external five-point 1-second `_Total` CPU gate with every point <=15%.
Stop at the first failed/missing point without registering a run. Within the worker retain
the existing start/round gates and add the same fresh gate before each measured child, outside
its stopwatch. Each child is bounded to 60 seconds and 160 MiB working-set/pagefile; stop
at the fixed UTC end even if its child allowance remains. Outer registration is exactly
28 MiB / 128 entries / 900 seconds. A retained atomic claim binds this condition to one
run, including failed runs; an external pre-registration stop receipt also closes it.
The final harness pins/static review are required before this marker admits execution.

### Frozen single-seal speed-frontier harness (2026-10-20)

| Script | Bytes | SHA-256 |
| --- | ---: | --- |
| `storage-lifecycle.psm1` | 172,644 | `4dc82cf72c3cdfac0eb80947234c92f5060e53f8207173a44aa874a3d19ed04f` |
| `run-storage-experiment.ps1` | 44,121 | `4d1fcdbc319583f7c8217bf2e5784565714d89a12b92e377e91ee13b7abc7a13` |
| `record-fast-7zip-screen.ps1` | 35,038 | `529f826f9c5705dbec1c60cedd72f129d7166aa860ce1104a481b8dd7e571e4c` |

All three PowerShell Parser checks returned zero errors. Independent read-only review
found two issues, corrected before any registration: case-variant condition names now
take the same required gates, and the frontier decision is published only after final
input/tool hashes and the time gate succeed. The final review has no unresolved P1/P2.
Module preparation validated the immutable marker, sources, tools and ZIP; an open-window
request correctly failed before 04:45 UTC. Invalid run IDs and case-variant calls without
the mandatory study switch were rejected. The complete intended invocation also rejected
before its window. No run was registered, no claim or stop file created, and no member
payload or codec command was evaluated in these readiness checks.

Invocation after fresh external admission uses `SpeedFrontierStudy=$true`,
`SourceCondition='SingleSeal20261020'`, `SevenZipLevels=@(1,3,5,7,9)`, worker timeout 900,
the marker's exact backslash-form input/tool paths, the full pinned ZIP SHA and
`InputRecoveryMembers=@('input/ptt5')`. Outer limits are 28 MiB / 128 entries / 900 seconds.
`Assert-KhcSingleSealSpeedFrontierCampaign -RequireOpenWindow` performs admission before
registration; the runner creates `claim.json` with CreateNew after registration, and the
worker verifies the same run ID and claim. The marker and old condition pins remain unchanged.

### Single-seal frontier admission outcome (2026-10-20)

The fresh open-window preflight at 04:45:10 UTC stopped before registration because
MSVC `vctip.exe` PID 25184 was running. Read-only confirmation at 04:45:25.7427883 UTC
found the same executable, created at 04:36:50.278029 UTC; its parent PID 45352 was no
longer present. Ownership/cause of that process was not established, and it was not killed.
All source, tool, input ZIP and harness pins passed, and no pending storage run was found.
A subsequent capacity-only check passed with the unchanged 290 MiB reservation:
4,337,616,651 B total, 332,770,656 B ordinary external, 4,002,516,202 B Cargo,
195,299,551 B lifecycle, and 504,979,087,360 B D: free. That diagnostic did not reopen admission.

The retained `pre-registration-stop.json` in the marker directory closes this exact
condition: zero registrations, zero CPU samples, zero codec commands, no claim and no
experimental work tree. The immutable marker is unchanged; there is no same-condition
retry or window rebasing. No generated experiment files require cleanup. This is an
incomplete environmental admission, not a codec performance no-go and not evidence of
speed, compression, memory, holdout or general superiority. The stop receipt retains
the observed process and verified pins for later interpretation; it may be removed only
when this campaign's evidence is deliberately retired, not to authorize a retry.

## KCS1 bounded event replay correctness preregistration (2026-10-20)

This is a separate implementation-cost candidate for KCS1, not a retry or successor
performance claim for the closed SingleSeal KRS2 condition. Before compilation, Rust
37-file source manifest is `ce9330c08bfd878fb5603f59c8a527c51307204d9c748bc98e88a3d2aa4335f6`
and KHC 27-file manifest is `d674bd9ec8a02e92f06e83f4b8e1a938292dbeda254afcc4b896cfdca0707572`.
Only `spatial.rs`, `khc/mod.rs` and `block/multi_range.rs` changed. KCS1's first Voter
walk records compact 8-byte Count/Literal events and its second walk is replaced by
replay. Count events and literal events are each at most N; the reserved and checked
event capacity is at most 2N, with no transcript allocation for N<=10. The transcript
is dropped before final-frame allocation and all stored fallbacks. Frame identifiers,
version, model, range decisions, CRC, statistics and tie ordering must remain unchanged.
The conservative spatial workspace bound rises from 2,461,908 to 19,239,124 B; actual
transcript/model/range capacities are checked, and SpatialMdl also charges its retained
MDL capacity against 64 MiB. This memory/time tradeoff is not yet a measured improvement.

The unchanged fixed development fixture, E2E example and worker are reused. Example
SHA-256 is `9d834c3c255fe2e14b920c47fca309bb1cb8d4e517b19ffc4221ede6faffd07c`;
worker SHA-256 is `099153c0493f6e8d1736f52cebdBF044c50baf64f0310c55f0bcdb0ab0177b8b`
(hex case is immaterial). Use one registered correctness run, 8 MiB / 96 entries /
300 seconds, 240-second children, with executable hashes appended before execution.
Require all existing 34 outcomes (14 success and 20 expected refusals), complete
restore/no-replace/corruption checks and the unchanged exact 24-suffix manifest
`57f34e63ea849913853d2487008121635d0a5416656101624a5f50fb6eb22b71`.
Failure is a no-go for this exact source condition, not a same-condition retry.
The finite suite includes empty/tiny/random/skewed/text/ptt5/block-boundary inputs,
KCS1/MDL/Portfolio selection and old revisions. Static post-implementation independent
review found no required correction; runtime and byte-identical verification remain pending.

Before overwriting the build output, the previous CLI was copied with hash equality
to the same task's `kcs1-replay-20261020/baseline-unlhare-cli.exe`, 2,583,552 B,
SHA-256 `453b03419aa5d22a0702fba32ecb30187637044c196163039923ff5962d9b6dd`.
Retain only for a separately preregistered old/new implementation-cost ablation or
reconstruction while this candidate is active; retire through Prunlet after equivalent
evidence is preserved and it is no longer needed. It is not a new input or holdout.
Cargo must use the serial wrapper and unchanged fixed storage budgets. Compilation
may expose the already recorded MSVC telemetry Job-drain problem; preserve that failure
as a separate result and do not weaken or bypass the Job drain checks.

### Replay candidate executable pins and build disposition

The one locked/offline Release compilation finished in 55.45 s, producing CLI
2,584,576 B SHA-256 `e13e110d491cac1a54ae340bca59f94f86ec55c951e65aab33a21daaea4b132e`
and E2E example 1,673,216 B SHA-256
`28a92e8a76fd2253ad03892001e254fe396ca8bbad1a0609546dfdcf50876601`.
The wrapper failed after 58.57 s because `vctip.exe` PID 23444 survived its 2-second
Job drain. The Job was terminated and a subsequent fresh process inventory was empty.
Release Clippy for lib/CLI/E2E with `-D warnings` also finished (2.97 s) but its wrapper
failed after 6.36 s on a different `vctip.exe` PID 12804. These are failures, not passing
build/lint results; no no-op re-run is used to relabel them. Rustfmt check passed.
Generated executable integrity and finite runtime correctness will be checked separately
with the pinned hashes above, the unchanged source manifests and registered E2E protocol.

### Completed MSVC replay correctness run

Run `9bfc7212c63c4154939758c47ac1e33c` passed the required 34 outcomes, with native
runner child exit 0, both EOFs and Job active=0. The 24 archive data suffixes matched
the frozen manifest exactly. Recovery ZIP is 746,809 B, SHA-256
`b5b8e5e1978f6f195a102fc539a8929cd3c70a68b6256f97e9bd03656fe4fc01`;
recovery manifest SHA-256 is `29cefab5c7ff62e223e758d6217be5d27ace87972bff4646bc0f5bd5421ec41f`.
Prunlet operation `dc7112872bde47d7b9e1a0d3045ff287` removed this run's 5,453,097 B
work tree and purged its redundant Prunlet payload after verifying the retained recovery
ZIP. All four cleanup receipts and final state `complete` / `AfterBytes=0` passed.
The source review and finite E2E pass do not replace the failed build/lint wrapper gates.

### Bounded task-local LLD validation attempt

The official rustc codegen-options documentation supports `-C linker` and
`-C linker-flavor=lld-link` for the Microsoft-link-compatible LLD flavor. The installed
Rust 1.98.1 toolchain contains `lib/rustlib/x86_64-pc-windows-msvc/bin/rust-lld.exe`,
reporting LLD 22.1.8. Make one separate attempt using that executable through
`CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_LINKER` and `RUSTFLAGS=-C linker-flavor=lld-link`
only in the invoking process, restoring inherited values on exit. Keep the same task,
serial wrapper, target, optimization, locked/offline dependencies, 256 MiB transient
build allowance, 64 MiB codec bound and all Job/drain/storage checks. Do not change
global Visual Studio/registry/privacy settings, install tools or relax failure checks.
This is toolchain isolation, not proof that the default MSVC environment is repaired.
If it fails, preserve the actual failure rather than repeating that condition.

The MSVC replay CLI was preserved with SHA equality as
`kcs1-replay-20261020/replay-msvc-unlhare-cli.exe` alongside the pre-change MSVC CLI.
Use that pair for any isolated source-cost ablation; comparing the old MSVC executable
with a new LLD executable would confound source and linker effects. Apply the same
retirement condition to this additional 2,584,576 B copy. If LLD compilation succeeds,
append executable pins and revalidate the unchanged finite E2E once for the new binaries.
No speed, memory or superiority claim follows from a successful linker substitution.

The task-local LLD attempt passed the unchanged full build wrapper (102.24 s,
observed Cargo peak 2,990,756,987 B) and Release Clippy with `-D warnings` (20.59 s,
peak 3,028,266,094 B). Both returned exit 0, no failure and clean child termination.
The default MSVC failures remain recorded above. LLD CLI is 2,577,920 B, SHA-256
`529af1304379eb13bf923f04db7a35b1f7540fc462578b1d266b6ba000d5e875`;
LLD E2E example is 1,671,680 B, SHA-256
`e893a7c2d891a697b3c4f8773b9f76cffc6d0940493eb94099b1a79aea867ba4`.
Before one new-binary E2E, freeze these hashes with the same source manifests,
fixture, worker, runner, 8 MiB / 96 entries / 300-second protocol and all 34/24
checks above. This repeats verification for a changed linker/binary condition, not
the already completed identical-binary condition or a performance evaluation.

LLD run `e026e44168d0497287db2bb92a90be83` passed all 34 expected outcomes and the
same exact 24-suffix manifest. The native runner also passed child exit/EOF/Job-zero
gates. Retained recovery ZIP is 746,807 B, SHA-256
`d141e191a110c8dcdd6ffb42c31ba58cd7ef17040aac48eaa864c80f118dc94b`;
recovery manifest SHA-256 is `2ce5c0319a76397dff5bc76efd1d8ce2f9e0aca154a5446d2a00f0f8e1a20dfb`;
the 7,162 B E2E report inside it has SHA-256
`975e9b0a636b2688dbd2d9a49ce8b5417fd16a3a3be47befde40bfd757716afc`.
Prunlet operation `ae8268e7d21c4a87af177f781a5eed68` removed this run's 5,453,097 B
temporary tree and purged its redundant backup payload. Final state and all four
receipts passed with `AfterBytes=0`. Retain both small E2E recovery ZIPs and their
receipts while they are the source/linker-condition reproducibility evidence; retire
only once equivalent evidence is preserved and those conditions no longer matter.
Restore using the existing verified recovery recipe, not by rerunning a closed condition.
The ordinary MSVC environment is still not repaired; only this explicit task-local
LLD build/lint/runtime condition has passed. Performance remains unmeasured.

## KCS1 replay source-cost / 7-Zip frontier preregistration (2026-10-20)

The final performance protocol is the same task's
`kcs1-replay-20261020/performance-protocol.json`, 3,945 B, SHA-256
`ed993052935ba26b3825c22535d05a10d9336941846e3abb6776be7d8bb34cec`.
Its 46 settings and seven file pins are frozen before external CPU admission or any
performance registration/codec command. Rust/KHC source manifests remain the replay
candidate's `ce9330c0...a4335f6` / `d674bd9e...0707572` recorded in full above.

| Harness | Bytes | SHA-256 |
| --- | ---: | --- |
| `spatial-replay-frontier.ps1` | 31,716 | `0c04f2e08123bc0fc054f4c984430f11d2e0fded3576c9af92cab22fdc7343e2` |
| `run-storage-experiment.ps1` | 47,360 | `b6c75139e0bbcf08994a8fb6a3822566a3d483f15e33f0c3e6cc4be13cc912e5` |
| `storage-lifecycle.psm1` | 172,644 | `4dc82cf72c3cdfac0eb80947234c92f5060e53f8207173a44aa874a3d19ed04f` |

Use the pinned old/new **MSVC** executable pair, not the newer LLD executable, for a
source-cost ablation without changing linkers. The sole input is the unchanged complete
development `input/ptt5` member, 513,216 B, SHA-256
`0ec3a75089bb52342813496b17e51377bc9eba3cb519a444d67025354841d650`, from the already
pinned 769,634 B recovery ZIP. Set this one source file's mtime to 2020-01-01 UTC before
all samples, require exact full old/new archive byte equality, and require actual single
revision-7 KCS1 frames. Do not derive a new principle or quantum advantage from replay.

Measure old KCS1, replay KCS1, and 7-Zip 26.04 at all `-mx=1,3,5,7,9`, with requested
`LZMA2:d=64m`, one thread, solid on, mqs/time metadata off. Report actual methods and
effective dictionaries. Keep KHC timestamp metadata in its full archive as a conservative
fee. Use five rotating rounds, no designated warmup, disclosing the incomplete balance
of five rotations over seven positions. Each sample includes separately timed native
create and real filesystem extraction, complete byte/SHA restoration and native integrity.
Unmeasured version/list/integrity operations precede extraction and can warm caches;
these results are not cold-start or storage-device throughput estimates.

The 7-Zip baseline is mechanically the eligible profile with the smallest median of
the five paired per-round encode-plus-extract sums (tie by strategy), among profiles
whose full archive is at least as large as replay KCS1. Require each directional median
<=95% of that baseline, no higher combined or separate directional working-set/pagefile
maxima, and no domination on size, both time medians and all memory measures by any
of the five disclosed profiles. Missing eligible baseline is a no-go. All profile data
must be retained even on a negative comparison. Separately disclose source-cost tradeoff:
encode median <=95% of old KCS1, extract median <=105%, and maximum OS memory no more
than old plus the design's additional 16 MiB allowance. This second tradeoff is not a
7-Zip frontier pass, and a mechanical finite pass is not error-free, heldout or general proof.

Parent admission must freshly verify pins/plain paths, no pending run or relevant
process, unchanged storage budgets with 290 MiB reserve, then five fresh one-second
CIM `_Total` CPU samples, stopping on the first missing/invalid/>15% value. If it fails,
do not register; use the worker's metadata-only `-StopBeforeRegistration` helper with
the same fixed protocol path/hash, bounded reason and 0..5 CPU samples. That helper
and registration/claim creation share the named admission mutex. Do not write a stop
receipt outside this mutex. It truthfully marks protocol pins as not independently attested.
Retain stop/claim forever for this exact condition; no retry, replacement clock window
or alternative root is allowed. No future absolute waiting window is introduced.

On admission, invoke only `ProtocolPath` and `ProtocolSha256` through the registered
runner at exactly 28 MiB / 128 entries / 900 seconds. The runner revalidates within
the mutex, registers, creates the claim with run-record SHA and a fixed UTC deadline
900 seconds after claim, then unlocks before child start. The worker checks this claim
and keeps start/round/every-measured-command five-point CPU gates outside stopwatches.
Each child is limited to 60 seconds and 160 MiB working-set/pagefile; EOF/Job drain,
positive OS counters, final source/tool/input/archive hashes and deadline are mandatory.
Only after final gates may decisions be published. Capture is bounded to 32 KiB per
stream for version, 4 KiB otherwise, report to 2 MiB UTF-8, with explicit tail flags
if trimming is needed. Real bytes/entries plus the report are checked before writing.
Failed commands and partial samples retain bounded outputs, timing, peaks and cleanup
status. Final Prunlet cleanup and receipt verification remain separate success gates.

Independent review identified and verified fixes for report capacity, missing failed
command evidence and stop/claim races. A parent check also ensured a start-CPU failure
can write its report into an empty registered work directory before payload creation.
The first metadata readiness protocol, 3,908 B, SHA-256
`c5ff18a97ab81df66c3bc58a91b1deb3d01e6dc7a8345d427aeefd2d984a0bea`, failed because
PowerShell auto-converted its ISO timestamp. It is preserved, not overwritten, as
`readiness-protocol-v1.json`. Before any actual admission, the worker was corrected to
require PowerShell >=7.5 and `ConvertFrom-Json -DateKind String`; thresholds stayed fixed.
The final independent review passed, both Parser checks passed, canonical metadata/pins
validated, and wrong protocol SHA, wrong outer budget and extra worker parameters were
rejected with zero registration delta and no claim/stop/payload/codec evaluation.
Keep the readiness file only as evidence of this pre-admission correction while needed;
retire with the candidate evidence after equivalent provenance is preserved.

### Replay frontier external admission outcome

The single actual external admission began at 05:22:28.8347537 UTC on 2026-10-20.
Fresh protocol/source/tool/input/harness pins, plain paths, no pending lifecycle run,
no relevant native process, and the unchanged storage budgets with 290 MiB reserve
passed. Fresh one-second CIM CPU samples were 6%, 12%, then 26%. The third value
exceeded the fixed 15% ceiling, so admission stopped immediately without further CPU
samples, registration, claim, payload extraction or any codec command. The runner
was not dispatched. There is no candidate/baseline performance result or codec no-go.

The same-mutex metadata helper created `performance-pre-registration-stop.json` at
05:22:37.1119203 UTC, 445 B, SHA-256
`c854dbf5e604599b1dd60a9a5fc6a7e6faf6018a815b5fe8fbd3825e96692603`.
It retains the three CPU values, reason and supplied final protocol hash, and honestly
sets `protocol_pins_attested=false`; the helper itself did not re-attest pins. A fresh
read-only validation refused the closed condition with `Campaign already claimed/stopped.`
The final protocol and original readiness file remain unchanged. This exact condition
cannot be retried, rebased or reopened after load falls. No experimental work tree or
new run was created, so this admission requires no temporary-tree cleanup.

A later 05:23:49.6585426 UTC read-only process-counter snapshot showed several Brave
processes and WmiPrvSE consuming CPU. This later snapshot cannot identify the cause of
the earlier 26% sample; no unrelated process was killed or reconfigured, and it was
not a second admission. Budget after closure: 4,523,022,457 B total, 339,754,510 B ordinary
external, 4,180,938,154 B Cargo, 197,104,881 B lifecycle, 504,607,961,088 B D: free.
Retain protocol/stop/readiness receipts for provenance and old/new executable copies
only while needed to reproduce the candidate or provide a source-cost baseline for
a materially improved implementation. Cleanup/retirement must not remove the stop
record as a way to authorize a retry. LLD finite correctness remains validated;
comparative speed, actual peak memory and the full GOAL remain unproven.

## Compact 2-byte KCS1 replay correctness preregistration (2026-10-20)

This new candidate reduces transcript representation rather than reopening the closed
8-byte replay performance admission. Before changing the source, preserve its 45 source,
Cargo/build and E2E/harness files in the same task's
`kcs1-replay-20261020/eight-byte-source.zip`, 213,310 B, SHA-256
`df6120ebf52c490a0c3ce6516423a6c4f3b7223cb3c416dd1d7b061d2533f49c`.
All ZIP entry bytes and SHA-256 values were checked against `source-files.tsv`.
This small snapshot preserves the otherwise untracked before-image for reconstruction
and comparison. Restore only selected source files into an approved external task work
area after verifying the ZIP/entry manifest; do not overwrite the current worktree.
Retire with Prunlet after equivalent source provenance is retained and it no longer
serves as a reproducibility or comparison baseline.

The proposed record is one u16: Count uses bit15 and its low8 byte, Literal only low10
bits for width minus one. Replay reconstructs Count varints, position and literal XOR
residuals from the immutable raw input and stored width. It checks reserved bits,
three-byte Count extent/continuation, remaining input, unfinished Count before literals,
and final position only after all events succeeded. A zero cumulative value is not
treated as a completed Count while continuation bytes remain. Range-output-limit early
termination must retain the ordinary stored fallback, without a misleading final-position
error. First-walk Stats, model order, range operations, CRC, formats and all tie rules
must remain unchanged. 2N checked event capacity now costs at most 4 MiB instead of
16 MiB, so the conservative spatial bound becomes 6,656,212 B, 12 MiB lower; OS peaks
and CPU tradeoffs are still unmeasured. Keep the same SpatialMdl retained-capacity gate.

Before production code edits, extend the existing E2E input matrix with zero lengths
10/11, 127/128, 16,383/16,384, random 775/776, and repeated pair-unique 1,024-byte rows
with a later literal mutation. Together with existing empty/tiny/literal-only/random/
ptt5/MAX-1/MAX cases this targets allocation threshold, Count continuation boundaries,
width1024 residual reconstruction, maximum terminal copies and early stored fallback.
Keep the same 34 native outcomes and frozen exact 24-archive suffix manifest, without
adding disk fixture files. This does not claim exhaustive allocator-failure coverage.

Preregister the formatted source before compilation: Rust37 manifest
`cfb9edc3fb19377cb597e3b98763aa2c5935c1b7946597251928816dd583079b`, KHC27 manifest
`bbe947dbacf824234b91702de233a5b9a8e51c4ddce27e310b6f462e5cf109c3`;
`spatial.rs` SHA-256 `38ebe608efe532a95f749a823131c836bc125b855bca0fc0b49d8c9a5471e91d`;
E2E example `dedf4913509a329e87809866638a80180cbe97747221416d098482703ce2a9ac`.
Only those two files differ from the preceding source/runtime condition. Use the same
task-local LLD linker settings and serial Cargo entry for release lib/CLI/E2E build
and Clippy, all fixed storage and Job/drain checks unchanged. Append executable pins
before one registered correctness run at 8 MiB / 96 entries / 300 seconds with the
unchanged E2E worker and current runner. Require 34 expected outcomes, full byte/SHA
restore and the unchanged 24-suffix manifest. Failure closes that exact source condition.
No comparative timing or holdout evaluation is authorized by this correctness run.

Independent post-implementation static review found no required S2 correction:
producer/replay position, three-byte Count extent, reserved bits, retained capacity,
fallible allocation and early range-limit fallback agree. The saved 8-byte baseline's
walk/pack, frame validation and decoder are unchanged. This is static evidence, not
runtime or performance evidence. Random lengths 775/776 do not establish arrival at
the model-length-770 eligibility branch. The pair-unique width1024 fixture establishes
the producer's intended width, but has no direct assertion that replay consumes that
literal before a possible early range-limit fallback. Keep those coverage limits
explicit; do not present the expanded matrix as exhaustive branch coverage.

S2 task-local LLD release build succeeded (wrapper exit 0, compiler 51.01 s,
wrapper 51.874 s); Clippy `-D warnings` succeeded (wrapper exit 0, compiler 2.27 s,
wrapper 3.252 s). Observed Cargo sampling peak was 3,036,179,446 B, below the
unchanged 6,175,228,536 B Cargo cap; not an OS quota or guaranteed peak.
Before registered native execution freeze CLI 2,578,944 B SHA-256
`bfaf5d2149d6dd1393f1c17a80c796886a3d224dd478490705bf8a01a1586260`
and E2E example 1,678,848 B SHA-256
`e297eb72fed330b26fc956485005eb1e396dc6472118305e8b68d839a11c2fa8`.
This does not repair or reclassify the earlier default-MSVC wrapper failures.

S2 native registered correctness run `01ea4f624410461b87cc7540611dada4` passed
34 outcomes (14 successes / 20 expected refusals), including complete API/CLI restore,
no-replace, nine malformed API archives and revision 1–9 reads. Runner child exit 0,
both pipe EOF and Job active count 0 are recorded in `runner-result.json`.
The parent independently recomputed all 24 KHC data suffixes (offset 32 plus LE u32
manifest length at byte20; ordinal name TAB suffix length TAB SHA256 LF) and obtained
the unchanged `57f34e63ea849913853d2487008121635d0a5416656101624a5f50fb6eb22b71`.
Only timestamp-bearing manifest bytes are excluded; no encoded frame byte is excluded.
Recovery ZIP is 746,811 B SHA-256
`df592d91fce744cd60a7f0372b9a29937cc237ae677c66ec49c1121b6a688236`, recovery manifest
`e4cb6753b0ac527f438bb6d62960dd3057dbed751e3bfc305e77c33a84a3a72e`, under the same
task retention run directory. Restore verified selected entries into an approved
external task work directory, not the repository. Retain this small evidence while
needed for source/output reconstruction; retire after equivalent provenance is kept.
Prunlet operation `4cc25b5e33774e7998eda68e1c8518bf` removed the 5,453,097 B temporary
tree, purged its redundant Prunlet copy, finalized with AfterBytes 0, and passed all
four completed receipt checks. The retained recovery ZIP remains available.
This proves finite correctness under LLD, not full branch/allocator coverage,
cross-platform native correctness, speed or OS memory superiority.

For a same-linker representation ablation, preserve the verified S2 source preimage
`compact-replay-20261020/compact-spatial.rs` (source SHA above) and candidate CLI copy
`compact-lld-unlhare-cli.exe` (CLI SHA above) in the same task retention root; all copied
bytes were rehashed. Reconstruct S1's sole differing production file `spatial.rs` from
the verified `eight-byte-source.zip`, require its original SHA and Rust/KHC manifests,
then build only its CLI with the same existing serial target/toolchain/LLD settings.
Copy and hash that baseline CLI, restore the exact S2 source preimage, and rebuild the
S2 CLI. Do not run a codec while the baseline source is staged and do not treat it as
the current product. This is ablation-artifact preparation, not permission to reopen
the closed S1 performance campaign. No second Cargo target or new task root is used.

Baseline artifact preparation initially built bin-only (wrapper exit0, 43.60 s),
yielding 2,577,920B SHA `f20ff982ee069539b7a9b59e70f1b8147f15701c1e92193263bc50690cd0f745`.
That graph omitted the example's Windows Threading dev feature and is NOT admitted
as the source-only performance baseline. Build both CLI and the same E2E example
for baseline and candidate, matching the already validated candidate build arguments;
the example is compiled but not executed while the S1 source is staged. No weaker
toolchain/feature graph is substituted for one side of the source comparison.

The matched CLI+example S1 build passed (wrapper exit0, 63.258 s; observed sampling
peak 3,047,056,598B). Its CLI is 2,577,920B SHA-256
`9a769212fd8f7a0db083a60b2dc7105da4edbff7145b8d30579029cecd33b273`, copied and rehashed
as `compact-replay-20261020/eight-byte-lld-unlhare-cli.exe`.
The first copy guard expected the historical S1 binary's SHA and refused the copy;
do not report that guard as a pass. PE COFF timestamp 1,792,475,062 is the new link
time, so byte-identical executable rebuilding is not assumed from identical source.
Freeze this newly built artifact, not the historical SHA, for the same-feature ablation.
The original S2 `spatial.rs` was restored through apply_patch and its exact SHA
`38ebe608efe532a95f749a823131c836bc125b855bca0fc0b49d8c9a5471e91d` verified before
rebuilding the canonical CLI. No codec was executed with the temporarily staged S1 source.

The canonical S2 CLI+example rebuild passed (wrapper exit0, 61.416 s, observed sampled
Cargo peak 3,045,424,957B). Canonical CLI is now 2,578,944B SHA
`e9089ace989eb762ba7543540cfc6e3e2e3a4faa4422bcabc87e7620cda76138`;
canonical E2E example SHA `3a997136ee91f6da26968d65c1aa22b476b084a1dec467eb01c08e97d8cd6a14`.
Comparison against the already correctness-validated frozen S2 CLI `bfaf5d...`
found exactly six different bytes. A COFF-only guard first refused to equate them.
PE32+ directory/section parsing then identified both metadata fields: COFF timestamp
at offset128 and IMAGE_DEBUG_DIRECTORY timestamp at offset2,391,328 (1,792,475,211
versus 1,792,474,503). Zeroing only those two documented four-byte fields makes every
remaining executable byte equal, normalized SHA
`ecd8ef12e88f5a26e2a41be39e08387470a4599ff63b06bfe67867faa7fd44d6`.
No broad binary region was masked. The prospective performance candidate stays the
original, byte-pinned `bfaf5d...` copy that actually passed the finite E2E.

## Compact S2 representation / five-profile frontier preregistration (2026-10-20)

This is one new admission for the substantive 2B/4MiB representation, not a retry of
the closed 8B condition. Current S2 source, frozen CLI and same-feature LLD 8B CLI
are pinned above. Dedicated worker `compact-spatial-replay-frontier.ps1` SHA
`ae56c4fc7e1aa841bb53dce0296695af7c9727a613cce60de059e84ca72f14c2` (34,361B), runner SHA
`dea6fa69bf57e20416e72b539bd4d3135a8a0ac2538f23a6193b3332f1903891` (48,697B), unchanged
shared module `4dc82cf72c3cdfac0eb80947234c92f5060e53f8207173a44aa874a3d19ed04f`.
Independent post-implementation review passed the original entry/state/report checks
and the final baseline pin / observed-range additions; both scripts have Parser0.
The old worker/protocol/stop are retained unchanged as closed historical provenance.

New canonical protocol is the same task retention child's
`compact-replay-20261020/performance-protocol.json`, 4,724B SHA
`e972887689551b2d6a0a34cc93491ddde18503a269ba7a8eb00510aa9f07cda2`.
Read-only readiness accepted all53 fixed settings/all7 pins and rejected wrong SHA,
27MiB instead of28MiB, and an extra parameter, without registration/claim/stop.
The first parent negative-test assertion expected the wrong error text (`changed`);
the actual worker correctly refused with `Protocol SHA mismatch.`. That assertion
failure did not change this protocol or perform CPU admission/codec execution.

Keep fixed ptt5, 7 strategies (8B LLD, 2B LLD, 7-Zip26.04 mx1/3/5/7/9), 5rounds,
0warmup, 5 incomplete rotations, OS filesystem extraction, full restore/CRC/determinism
and exact old/new archive equality. Requested 7-Zip LZMA2 d64m / one thread / solid
is fixed; report effective dictionary even if the tool clamps it to input size.
Full archive sizes include all restoration metadata; KHC timestamp overhead is not
deducted. This is development-only, not holdout or general superiority evidence.

The 7-Zip screen selects the fastest combined-median profile among all five with
archive size at least as large as the candidate. Require candidate encode/extract
medians each <=95%, all four directional plus aggregate WS/page peaks no greater,
and no domination across all five profiles. Before measurement add an uncertainty
guard: candidate slowest of five encode/extract samples must each be <=95% of that
selected profile's respective fastest sample. Keep min/max in every summary. This
is a conservative observed-range screen, not a statistical confidence interval.
The separate source-memory tradeoff requires both median times <=105% of8B,
all6 memory metrics non-increasing and encoder WS or page peak at least1MiB lower.
It does not relax or substitute for the full 7-Zip screen.

One admission/zero retries; CPU5 fresh one-second CIM samples, every point <=15%,
before registration and at start/eachround/everycommand(including list/test/version)/
final. Dedicated common NamedMutex binds stop issuance and registration→CreateNew
claim. Any admission failure closes this exact condition using the stop helper;
never reopen it after load falls. Registered capacity remains28MiB/128entries/900s,
child60s/160MiB, per-command capture4KiB(32KiB version), report<=2MiB UTF8 prewrite.
Failed command, partial sample, EOF/Job and cleanup failures remain evidence.
At readiness, total4,540,229,597B / Cargo4,191,846,159B / ordinary346,053,645B /
lifecycle198,007,548B; all fixed caps and290MiB reserve passed, D free504,599,855,104B.
No codec or performance admission has run at this preregistration point.

Actual S2 external admission at 2026-10-20 05:50:49.5117354–05:50:57.8473837 UTC
passed pins, relevant-process absence and storage reserve, but sampled CPU7%,9%,47%.
The third point exceeded15%, so the dedicated same-mutex helper closed the condition
BEFORE registration/claim/input extraction/any codec. Tool exit2 is an admission
refusal, not a codec failure or a successful performance run. The canonical protocol
remains unchanged. Stop receipt is 454B SHA
`ae9f8a7c9b89e852ae9a37eade84cfecdc9d5a60d6a2813256d259d57d7dcb85`, with
`protocol_pins_attested=false` (the stop helper does not attest the caller's pin checks).
No claim or new experimental work tree was created; no runtime cleanup is needed.
With the required task ID set, read-only ValidateProtocolOnly recheck refuses
`Campaign already claimed/stopped.`. An earlier parent recheck omitted that task ID
and therefore checked the wrong guard first; do not count it as closure validation.
This exact S2 timing condition cannot be retried/rebased/reopened when load falls.

A later read-only per-process CPU snapshot at05:52:17.899 UTC showed several active
processes and an observing pwsh using CPU. This later sample does not attribute the
earlier47% event to any process or prove that the CPU observer caused it. No unrelated
process was stopped or reconfigured. Retain protocol/stop/artifact/source provenance
only while needed for reconstruction or a substantively different comparison; do not
delete stop state as a retry mechanism. Finite S2 correctness and the logical12MiB
bound reduction remain established; speed, OS memory and7-Zip superiority remain
unmeasured, and the full GOAL remains incomplete.

A separate bounded observer diagnostic (not admission, benchmark or codec retry)
took six paired native GetSystemTimes / CIM observations at05:55:32–05:55:39 UTC.
Native sleep-interval busy percentages were13.72,12.11,17.43,11.79,11.30,11.17;
CIM reported11,9,18,5,10,13 over its own formatted-counter intervals. Observation
intervals are not identical, and these later values do not identify the earlier47%
event. In particular native sampling also exceeded15% once: the evidence does NOT
establish a defective CIM meter or justify discounting the recorded admission refusal.
The observer itself consumed0.047–0.344CPU seconds per cycle on12 logical processors.
No other process was stopped; no CPU threshold or closed protocol was changed.

Retain only the small script/data pair under the same canonical campaign for observer
method provenance: `cpu-observer-check-20261020.ps1`,3,665B SHA
`bff893a5a4cc645d938f4673a6d6244c4e95c6d103486a215ae9684cba79e2aa`, and JSON1,904B SHA
`4272189d2ca162242662c1165e60f50cf24006cbcd48ca71f579db36653e5ee7`.
Both were moved from the task work root with source/destination ancestor checks and
matching hashes; no temporary diagnostic output remains there. For reproduction use
the script in an approved task work area with its fixed D task TEMP/TMP and a fresh
output filename; this is metadata observation only and grants no timing re-admission.
Retire this evidence once an equivalent observer provenance record is no longer needed.
Post-diagnostic total development storage4,540,235,620B, Cargo4,191,846,159B,
ordinary346,059,668B and lifecycle198,007,548B remain below their fixed caps.

## Folded-zero-Count S3 preparation (2026-10-23)

Resume authorizes continued implementation, not replay of either closed timing condition.
Investigate a substantive representation reduction: fold standalone Count(0) into bit14
of its immediately following Literal record. Positive-copy varint bytes retain their
Count records. Since each positive copy's k bytes satisfy k<=copy length, and each
Literal contributes one record including any Count0, record count<=input length N.
The proposed maximum transcript is2MiB instead of4MiB; the spatial bound would become
4,559,060B. Independent read-only producer/caller analysis found no counterexample,
but runtime/CPU/OS peak benefits are not established.

Before changing production code enumerate failures: folded Count0 lost from histogram
or emitted after literal bits; bit14 contaminating width; treating a positive varint
component as Count0; unresolved/consecutive pending Count0; record-count/capacity excess;
CountOnly/materialized disagreement; incorrect final-copy position; early range-limit
fallback turned into completion error; changed wire/model/tie order; changed pack/drop
allocation overlap. Retain existing malformed/length/revision/no-replace E2E coverage.
Extend the existing finite E2E before production edits with ff*64, ff*129, and
zero*128 + [ff,00] + zero*127. Require their Spatial method1 route, full roundtrip,
determinism and existing Portfolio strict-minimum checks. First capture their complete
prechange frame hex in the native report, then lock those bytes as golden assertions
before production edits. Existing24 archive suffixes must remain unchanged.

Preserved S2 before-image under the same task retention child
`folded-zero-count-20261023/two-byte-unfolded-source.zip`,215,213B SHA
`5f3cdf21cf80ae1c5113f07ae8fcca2ed382cf388b1533d5fbd9ab958b83c3b3`.
It contains45 source/build/harness files plus generated source-files.tsv,46 entries.
Initial generation stopped at the old archive-only manifest name; no source was edited.
After enumerating the actual45 source entries, verify each against the current source,
then append a fresh ordinal path/length/SHA manifest before finalizing this snapshot.
Retain only for source reconstruction/ablation; verify manifest before restoring selected
files into approved external task space. Retire with Prunlet after equivalent provenance
is kept and this before-image is no longer needed. No second task/Cargo target is used.
Use same serial Cargo entry, toolchain1.98.1/task-localLLD, full CLI+example build graph;
no version/dependency/public API changes. Baseline and postchange finite E2Es each need
fresh byte-pinned executable preregistration at8MiB/96entries/300s(child240s), cleanup
and exact24-suffix check. This section grants no comparative performance admission.

Pre-production baseline source freeze: unchanged spatial SHA
`38ebe608efe532a95f749a823131c836bc125b855bca0fc0b49d8c9a5471e91d`, Rust37/KHC27
manifests `cfb9edc3fb19377cb597e3b98763aa2c5935c1b7946597251928816dd583079b` /
`bbe947dbacf824234b91702de233a5b9a8e51c4ddce27e310b6f462e5cf109c3`, extended E2E SHA
`1404e331a75cc829fb9ab4fe9d303d8f42b10b1991a8ee4b046e1dcd88b96eb2`.
Compile this condition once, append resulting executable pins before registered execution.

Extended-baseline release build passed wrapperexit0,20.077s(compiler19.15s).
Freeze unchanged CLI2,578,944B SHA
`e9089ace989eb762ba7543540cfc6e3e2e3a4faa4422bcabc87e7620cda76138`, extended example
1,692,672B SHA `101716831def21216d2442a0e67daeaef8785030b6823dea3c37ad98d364b818`.
Unchanged worker `099153c0493f6e8d1736f52cebdbf044c50baf64f0310c55f0bcdb0ab0177b8b`,
runner `dea6fa69bf57e20416e72b539bd4d3135a8a0ac2538f23a6193b3332f1903891`, shared module
`4dc82cf72c3cdfac0eb80947234c92f5060e53f8207173a44aa874a3d19ed04f`. Execute only the
one preregistered8MiB/96entry finite baseline E2E, not a timing campaign.

Baseline run `3e8983eeee7146fe8729467941ab7b25` passed34 outcomes(14 successes,
20 expected refusals), all three extra Spatial frames used method1 and roundtripped.
Runner child0/Job0, independently recomputed24 suffix manifest stayed57f34e63...22b71.
Recovery ZIP747,043B SHA `e9e98b44db092e24fdc0502bf20f6ed3511985ad02f96a42ab012904e29e9cf3`.
The three full baseline frame hex strings are now golden assertions in the existing
E2E example, added before production edits. Baseline temporary tree5,453,487B is being
Prunlet-cleaned; do not build/register another run until lifecycle finalization.

S3 implementation preserves hist/Stats and encodes folded Count0 immediately before
the Literal's entropy bits. Its width masks low10, checks all remaining reserved bits,
uses N-record exact reservation and checks dangling/invalid pending Count0. CountOnly
and early-output-limit/drop paths are otherwise unchanged. Formatted source freeze
before compilation: spatial SHA `f1303a3f667c4922cd5db0f1debdddcd0efc446bb5fb3802a5ecc80832d265ce`,
golden E2E SHA `1efe551bea28206349c7efce47f4eb87f26de06eacab330df0f6e89094456b7a`;
Rust37 `e2937796951ad225df95c1224e60fbf0f6a0dc848d699d5e80a03e15885aa8ea`, KHC27
`df6708f50cc3804f75967434fe6f5848eb366add2b27308bc640575ff091c74c`.
Direct same-toolchain rustfmt check passed. Await independent post-implementation
review, then same LLD build and Clippy before pinning the one finite postchange run.

Independent post-implementation static review passed: no P1/P2, N-record proof and
2MiB/4,559,060B accounting agreed. Model/CRC/walk/pack/frame validation/decoder and
mod.rs are unchanged from S2. CountOnly remains observed indirectly through Portfolio
selection, not an exhaustive direct length-value comparison; no CPU/OS peak claim.
Baseline cleanup operation `cb591a72e6364073a6de5c85d6fdf3d9` completed after73.8s of
Prunlet recovery-lock wait. All four receipts verified, finalizedBefore5,453,487B/After0.
No cleanup bypass, second Cargo target or historical timing campaign was used.

S3 release build passed wrapperexit0,80.901s(compiler1m17s), sampled peak3,045,452,280B.
First Clippy attempt FAILED: wrapperexit1 after83.338s at its128MiB transient guard,
sampled start3,039,198,769B/peak3,171,405,509B. Do not relabel it as lint success.
Although the wrapper pins Cargo/RUSTC1.98.1, its external cargo-clippy dispatch followed
the repository rust-toolchain.toml channel1.99.1 through rustup, which auto-installed
that missing toolchain and began a separate dependency graph. No production source
error was established before the guard; no child cargo/rustc/clippy-driver remained.
The existing1.98.1 clippy-driver reports0.1.98(48a229ceae2026-09-01).
For this same-toolchain S2/S3 ablation only, isolate the next Clippy invocation with
process-only RUSTUP_TOOLCHAIN=1.98.1-x86_64-pc-windows-msvc and RUSTUP_AUTO_INSTALL=0,
in addition to the existing LLD flags; restore inherited values afterward. Keep the
128MiB transient/global caps and serial target unchanged. Do not alter the repository's
1.99.1 setting, global Rust configuration, auto-installed shared toolchain or old pins.
Validation under the repository-default1.99.1 remains a separate uncompleted scope.

Isolated1.98.1 Clippy passed wrapperexit0,11.702s(compiler8.12s), with unchanged128MiB
transient gate and sampled peak3,171,407,744B. Freeze S3 CLI2,578,944B SHA
`a5081f1a8fd0beb4138f64ff2bcef768281c8f2a2901f4470b33475705017d34`, E2E1,694,720B SHA
`8be86f6261754bf351c5d2696aadf59b7aa75a141e85362a887419e520d9409c` before its one
postchange correctness run. Require all three prechange frame goldens,34 outcomes and
the unchanged24-suffix manifest at the already fixed8MiB/96entries/300s(child240s).

S3 postchange run `2e2e12f4afea4dbe8028bbb7b0f4ad9e` passed34 outcomes(14/20), all three
complete S2 frame goldens and24 archive suffix manifest
`57f34e63ea849913853d2487008121635d0a5416656101624a5f50fb6eb22b71`.
Runner childexit0/Job0. Recovery ZIP747,028B SHA
`d9a8f8f7ac1f5f9897d83a82449410c1659ac57025f79d2d5a0f6a10e05ec66e` remains in its
same-task lifecycle run directory for reconstruction, not as a new performance fixture.
Prunlet operation `575ddd0e71744189a65376dbf4cc1f47` removed5,453,487B, redundant payload
purged, four receipts verified and finalizedAfter0. Both finite runs are fully cleaned.
Frozen S3 CLI copy under the same S3 retention child `folded-lld-unlhare-cli.exe`
matches a5081f.../2,578,944B. Keep it with the verified S2 bfaf5d... copy only while
needed for source-cost reconstruction; retire through Prunlet after equivalent provenance.
Postcheck total4,677,069,207B / Cargo4,324,079,804B / ordinary350,659,610B /
lifecycle199,813,333B; fixed caps and290MiB reserve passed, D free469,658,402,816B.
These are development storage figures, not archive size or runtime memory peaks.

Before any S3 performance protocol/admission, rechecked current stable 7-Zip on2026-10-23:
official https://www.7-zip.org/download.html and
https://github.com/ip7z/7zip/releases/tag/26.05 identify26.05, published2026-10-21T13:05:54Z.
Thus the initial unexecuted S3 harness draft's26.04 was not an eligible current baseline.
Do not change historical26.04 records. No protocol or timing sample existed at this update.
The GitHub connector was unavailable after its required Toolport capability lookup;
public official release metadata was read through the permitted CLI fallback. The hook's
initial pre-search refusal executed nothing; its required search was completed before retry.
Official asset7z2605-extra.7z is1,763,900B, GitHub SHA256 digest
`f27a8f103c84785026edcba1f67faf1357225df9d19ddb0b7760d55947141bc7`.
Streamed download used a30s deadline, exact-size cap/CreateNew and matched that digest.
Retain it in the S3 task child for provenance. Using installed26.04 only as a setup
extractor, unpack selected x64/7za.exe,License.txt,history.txt,readme.txt into the plain
`sevenzip-26.05` child; exactly four files exist there. No system installation changed.
Portable x64 standalone7za.exe is1,334,784B SHA
`7ddf0a3bc451e166679296be630d6f0573eb386159c04184761c43020c484291`, PE8664/FileVersion26.05,
informational banner `7-Zip (a) 26.05 (x64)` dated2026-10-21. It supports the unchanged
7z/LZMA2 comparison; no weaker codec/options are substituted. This tool preparation and
version query did not run the KHC candidate, timing workload or CPU admission.
Retain executable/license/source asset only while needed to reproduce this versioned
comparison; retire with Prunlet after equivalent version provenance is kept.

X supplement: Plumivox Toolport initially failed to connect. Required alternative
grok:source-command-x workflow completed fresh foreground jobtask-mvjvaaaz-zmla9g,
then read its stored result. Query period2026-10-17–23, topic7-Zip26.05 official release,
at most2posts: @Umineko19930417 onOct21
https://x.com/Umineko19930417/status/2113002135923327135 and @e999a2e785a7 onOct22
https://x.com/e999a2e785a7/status/2113126975481229823. Returned summaries agree with the
official release but are unofficial; complete raw post bodies were not independently
verified here, so they are supplementary pointers, NOT authority for the stable-version
decision. Companion output is under the existing work task's
`grok-sevenzip-2605-20261023` managed state for search provenance; preserve until that
provenance is no longer needed, with no repository/Codex-home task output.

S3 worker final preprotocol version35386B SHA
`91247ea29594b0c773f7dbba1af6794eea69ae20aa206b709ec1e3fd2af13106`, runner49925B SHA
`c14c33d53415e8fef48eeda99f4b66b48c5eda60a45a47e845f37025dc64c1e1`.
Dedicated schema/campaign/mutex separate it from closed S1/S2. Static review of the
original S3 dispatch passed; final26.05 portable-pin/banner delta awaits independent review.
All 7-Zip gates remain unchanged. Source-only S2→S3 memory gate is0.5MiB rather than
S2's separate old1MiB gate: ptt5 N513216 makes the predicted reserve reduction1,026,432B,
less than1MiB, so0.5MiB is fixed conservatively BEFORE the new S3 measurement. This
neither revises old results nor lowers the full7-Zip median/range/memory/frontier gates.

Final26.05 delta independent review passed: restoring only the version/distribution/
portable pin/banner delta recovers the earlier reviewed S3 worker byte-for-byte.
Protocol is now frozen in the S3 retention child `performance-protocol.json`,5,447B SHA
`729b58dfdd5493d25d80dc134fcd50f541cf4c570e0916ab3be640d2228833fa`,55 settings/7 pins.
Read-only readiness accepted it and rejected wrong SHA,27instead28MiB and an extra
parameter, with registrationdelta0/claimabsent/stopabsent. No CPU sample was taken yet.
Authorize exactly one external admission: revalidate pins, no relevant compiler/codec
process, no unfinished lifecycle and290MiB reserve; then5 fresh1s CIM CPU points<=15%.
On any refusal, same-mutex stop helper closes this S3 condition before registration;
no retry/rebase after load falls. On pass, exact28MiB/128entry/900s runner creates its
single claim and executes the reviewed worker with child60s/160MiB and all inner gates.
Every successful/failed sample remains recorded; all5profiles and both source/7Zip
decisions must be reported without turning partial data or admission refusal into a win.
Do not alter closed S1/S2 state, current55 settings, or any capacity to force admission.

Actual S3 admission at2026-10-22T18:28:42.0363153–18:28:48.9987815Z
(2026-10-23 03:28 JST) passed pins/relevant-process absence/storage but CPU points7%,37%.
Point2 exceeded15%; same-mutex helper closed BEFORE registration/claim/any candidate
or comparator timing workload. Exit2 is admission refusal, not codec no-go or a speed win.
Stop receipt452B SHA `66c33ae80f1ba027a37a695eda726b1a95d9d8ee9bcb01ee3830f9538e34b1fa`,
UTC18:28:48.9717026Z. Claim remains absent; read-only validation now refuses
`Campaign already claimed/stopped.`. Protocol729b58... remains unchanged. No performance
work tree/run or incomplete cleanup was created. This exact S3 condition is closed and
cannot be reopened after load falls or by changing only a hash/root. No CPU/OS-memory/
7Zip advantage was measured. S3 finite correctness and2MiB logical reserve reduction
remain valid; representative/unseen superiority and full GOAL remain incomplete.

Final bounded task-tree storage4,680,205,241B, Cargo4,324,079,804B, ordinary353,795,644B,
lifecycle199,813,333B, below existing caps; no compiler/codec processes remained.
The failed Clippy's automatically installed shared Rust1.99.1 toolchain is separately
657,417,448 logical file bytes(166files) under the existing Rustup-managed C toolchain
root. It is NOT included in the task-tree number; allocation overhead/download caches
are not measured. Preserve this repository-required shared toolchain rather than
deleting global data to conceal the failed attempt. No manual task output was placed
there. The two figures together are5,337,622,689 logical bytes, not a whole-machine
development-storage measurement or runtime process peak.
Resume requires a genuinely available evaluation environment/new authorized conditions,
not blind retries or cosmetic packing changes to evade these closures. Existing native
correctness evidence, source before-image, current stable comparator/license, and closed
protocols are retained for reconstruction; successful finite-run temporary trees are gone.

## Explicit default-toolchain validation preparation (2026-10-26)

Resume does not reopen any closed S1/S2/S3 performance campaign. This independent
validation checks the repository's installed Rust1.99.1 without codec/source/wire changes.
The serial Cargo wrapper previously fixed both Cargo and RUSTC to1.98.1, so setting only
RUSTUP_TOOLCHAIN would mix toolchains. An explicit installed-version selection retains
1.98.1 as the historical default and sets Cargo/RUSTC/child Rustup consistently; automatic
installation is disabled. Invalid or missing versions must fail before output initialization.
Existing task/target, jobs1,180s deadline, fixed caps, pending-run/lease/reparse checks and
sampling limitations remain unchanged. The wrapper is not among the frozen S3 protocol's
seven pins; the protocol, worker, runner, shared module and stopped markers stay unchanged.

Before execution, enumerate refusal/failure axes: invalid/missing toolchain, inherited
Rustup conflict, pending lifecycle or lease, invalid/reparse output, insufficient storage,
compile/lint error, log bound, transient budget,180s timeout and surviving Job process.
Use the same goal-restore-20261019 task/target with a separately reserved512MiB transient
allowance (existing maximum, not a change to any performance or fixed storage limit).
Initial task-tree usage4,680,205,241B and Cargo4,324,079,804B passed a1GiB reserve probe;
no relevant compiler/codec process was found. The frozen S3 CLI and current CLI both
remain2,578,944B / a5081f1a8fd0beb4138f64ff2bcef768281c8f2a2901f4470b33475705017d34.
Planned check: Rust1.99.1 release Clippy on lib/bin/existing finite E2E example, locked and
offline, warnings denied, with installed1.99.1 LLD. This is not an MSVC-linker or runtime
E2E pass, and no timing or OS-memory advantage follows. Recheck frozen pins afterwards.

Execution results: wrapper SHA94d7ec3e7d65f333851d6225aa4794ab92b3c7e1b11f1877848c3da17c203166;
PowerShell parser0errors and invalid1.97.0 parameter binding rejected without executing
the wrapper. Release Clippy passed exit0 in42.1741254s, sampled start3,171,407,744B and
peak/end3,200,425,467B. A live process snapshot showed installed1.99.1 Cargo, cargo-clippy
and rustc (plus the normal rustup proxy), rather than the former1.98.1/1.99.1 mixture.
Separate locked/offline release `build --lib` passed exit0 in73.1821452s, sampled
start3,200,425,467B and peak/end3,349,438,043B. Both used installed1.99.1 LLD and the
same512MiB/180s wrapper; neither establishes MSVC-linker or1.99.1 runtime E2E success.
No product source was edited; `build --lib` did not regenerate CLI, example or performance binaries.

Afterwards all seven frozen S3 protocol pins matched exact lengths/hashes, protocol
729b58df...8833fa and stop66c33ae8...4b1fa were unchanged, and current/frozen CLI a5081f...
as well as spatial sourcef1303a... were unchanged. No relevant compiler/codec process
remained. Task-tree usage4,858,235,540B, Cargo4,502,110,103B, ordinary353,795,644B and
lifecycle199,813,333B stayed inside all fixed caps. The178,030,299B Cargo increment is
retained in the existing shared task target for future validation, not copied elsewhere;
no temporary run tree or cleanup debt was created. `git diff --check` passed with existing
line-ending warnings. No closed campaign was retried and no new performance result exists.

### Rust1.99.1 CLI/native finite E2E follow-up (2026-10-26)

The next independent correctness step builds release CLI plus the existing
khc_spatial_mdl_e2e example using the explicit1.99.1 wrapper, installed1.99.1 LLD,
locked/offline dependencies,512MiB transient and180s deadline in the SAME task/target.
This replaces only the ordinary canonical1.98.1 build outputs; the retained S3 performance
CLI a5081f... and all closed performance campaigns remain unchanged.
Before any registered runtime, record the newly built CLI/example lengths/SHA and the
unchanged E2E worker/runner/module/source pins. Use the existing spatial-mdl-e2e worker,
8MiB/96entries/300s outer/240s child and the original pinned ptt5 recovery ZIP.
Require the existing34 outcomes, three full folded-Count0 frame goldens and all24 archive
suffix hashes to match the1.98.1 runs; decode full bytes, determinism and refusals must pass.
Failure axes are build/lint errors, mixed toolchains, missing or changed pins, pending
lifecycle/lease/storage refusal, timeout, output/record bounds, frame/restore mismatch,
wrong refusal, incomplete Job/EOF/drain and failed recovery/Prunlet cleanup. Do not infer
speed or OS-memory improvements from correctness. Freeze before runtime and execute once.

CLI/example build passed exit0 in73.2047598s; sampled start3,349,438,043B,
peak3,369,861,389B, end3,362,985,099B. Canonical1.99.1 CLI is2,580,992B SHA
e566440f6f0139b4c58d166a840170fbe2eb5b5b8690404796359e3a17786c1e; example1,692,160B SHA
dc810c0222a0113681552a501ba059d9fda5ec5ce3def5968aa9bd2a4ee032db.
Current Rust37 manifest remains e2937796951ad225df95c1224e60fbf0f6a0dc848d699d5e80a03e15885aa8ea,
KHC27 df6708f50cc3804f75967434fe6f5848eb366add2b27308bc640575ff091c74c.
Task-tree total4,871,782,596B and Cargo4,515,657,159B remain within fixed limits.

Runtime registration is held BEFORE creating any run/work tree: current global
PRUNLET.md documents schema6 Recycle Bin file deletion, with purge restricted to legacy
schemas1-4 and registry snapshots. Existing Assert-KhcPrunletItems/Finalize still require
per-file hashes and four delete/purge receipts. Verify installed CLI/schema compatibility
and a valid bounded cleanup path before running E2E; do not invent purge success, use a
different deletion path or register work that cannot finalize. No native1.99.1 E2E or new
performance result is claimed from the successful build.

Read-only boundary investigation confirmed the installed CLI help describes Recycle Bin
deletion and no Prunlet purge of Bin contents. Its `version` verb is unsupported; PE version
fields are empty, so do not invent an installed version number. The current Prunlet source
DeletionService.Recycle.cs:138-144 sets deleted status without return-item size/SHA;
:299-306 returns retained items plus warning for schema6 purge. Those source details are
not an independent proof that installed bytes match source. They agree with the observed
help and explain why this repository's strict legacy receipt checker cannot be assumed
compatible. Current lifecycle remains byte-for-byte unchanged; no deletion was attempted.

The next correction must preserve authenticated per-operation linkage and the pre-delete
full-byte recovery inventory, not simply waive missing hashes, accept retained as purged,
or call a different deletion implementation. Schema6 retained payload must remain charged
conservatively within existing development-storage limits until independent retirement
evidence exists; moving it to the Recycle Bin does not prove physical space reclamation.
Specify and review the schema6 lifecycle and a small bounded boundary verification before
registering the normal codec E2E. Legacy receipts and all closed protocol history stay intact.

### Schema6 boundary correction / one micro-probe (2026-10-26)

GOGO PRN-1 is the legacy-only cleanup/root-item receipt incompatibility; PRN-2 is the
operation/payload proof prerequisite; PRN-3 is retained Recycle Bin payload/metadata charging.
All remain unfinished until runtime and independent checks pass. Preserve the old module
4dc82cf... exactly as schema6-cleanup-20261026/storage-lifecycle-before.psm1 in the SAME
retained task. Legitimate current-source maintenance may change its future hash, but never
rewrite a historical protocol pin, marker or closure; no performance campaign is reopened.

Before production edits, one bounded installed-CLI probe uses that child's own payload:
one known text file and one empty directory, max64B/3entries. Reserve2MiB artifacts plus
1MiB external operation metadata within existing caps (initial4MiB reserve check passed).
No benchmark or codec is run. Preregistered contract/paths are retained beside the payload.
Require pre-delete full inventory and ZIP byte/hash agreement; exact CLI preview/delete;
original path absent; root-level returned operation/path/kind/status; returned Bin backupPath
and all payload contents matching inventory; own operation manifest/completion linkage;
same returned-operation CLI restore; all restore items successful, full source tree equal
and prior Bin payload absent before reducing retained-payload charge. Keep the tiny restored
fixture for reproduction. CLI observation budget180s each; timeout is UNKNOWN, not failure
or permission to retry/restore; inspect/wait the same identified process before any next step.

Failure axes fixed BEFORE execution: changed CLI/config/fixture, reparse/ACL/identity issue,
malformed/missing/duplicate/extra receipt or entries, wrong operation/path/backup binding,
changed bytes/empty directories, unexpected statuses/warnings, source/Bin ambiguity,
metadata unreadable/over1MiB, storage refusal, observation timeout/live process and failed
restore. No retry, alternative deleter, schema6 purge or invented zero retained capacity.
On ambiguous state retain the conservative64B+1MiB charge and recovery evidence.

Micro-probe completed: actual installed CLI preview/delete/restore each exited0 in<1s.
Operation59325e63acad49cdb791e61fd03ebaf1 deleted the exact payload root; CLI returned one
root-level item, null size/SHA and the Windows Bin physical backupPath. Pre-delete ZIP,
Bin payload and restored source text matched ALL27 bytes; the empty directory matched.
Own schema6 manifest/complete receipt bound operation/original/root/manifestSHA/PIDL and
volume/FileID; operation directory had no untrusted write ACL rules and no reparse ancestor.
After restore all items were restored, prior Bin payload was absent and the source tree
matched. Retain the tiny restored fixture,233B ZIP(SHAf6abcb511823048a0286cd6b3c4703b10f17e6c6513e3184c2efc38be20b7dd9)
and receipts as reproduction evidence. Own C operation metadata grew6,237→11,373B and was
copied byte/hash-exactly into the same probe child. Keep the conservative1MiB external
metadata charge until the normal budget reader includes it; restored payload charge0 is
supported by full source equality, successful restore and Bin absence, NOT physical savings.
The first read-only metadata parse failed because its security dictionary has an empty
root key; ConvertFrom-Json -AsHashtable read it correctly. No delete or restore was retried.
The informational help call with --config before --help was unsupported; standalone --help
was checked against Program.cs and succeeded. These are not failed deletion attempts.

### Reviewed schema2 implementation and explicit bootstrap (2026-10-26)

Current module SHAcd532811822c92f79c4d10e32556141d3914fe5adb65745bdf85a7929932bd67,
cleanup entryf1896639fdc5bf6b5258f6151f16b5d0b0a24526a1c6516d211913633ba6c63d,
prior-to-code boundary harness29b0a9b249738551bbb4fdaa413eafdcec22b58ccea89576edd7cf88105a1e45.
Fresh independent review initially required fixes to public-complete spoofing, marker
removal/schema downgrade and simultaneous persistent-reservation/ZIP lifecycle accounting.
Those were fixed and re-reviewed:59 boundary cases and3 parsers passed; no remaining P1/P2.
Scope is PRN-1 plus PRN-2/3 proof/storage conditions, not a codec/performance alteration.

Normal paths require the private current-task recycle-v6 root and never auto-reinitialize
missing state. Private reservations precede child/request, bind registration/marker and
persist on interruption. Central private-first classification guards registration/Cargo/
Prepare/Recover/cleanup/complete; public complete alone is never sufficient for schema2.
Registration lifecycle requirement is L+C+(P+M)+P+(M+1MiB), M=1MiB+entries*64KiB;
entry room uses (cap-L-C-2P-3MiB)/128KiB. Prepare and finalization check before writing
ZIP/proof. Existing caps and old schema1 verification remain unchanged. New finalization
validates the live Bin tree and own protected operation metadata, binds saved proof/request/
ZIP/executable to a private final record and does NOT call purge. Bin retained payload and
external metadata remain charged afterwards, even if Windows later removes them.

Parent independently ran59 cases, explicitly initialized the protected current-user/System/
Admin trust root once and verified its protected DACL/current owner. Original schema1
completed runs3e8983... and2e2e12... still passed all4 receipt checks, untouched. Initial
new-budget total4,873,018,759B comprises actual task trees4,871,970,183B plus probe's
1,048,576B external-metadata charge; retained Bin payload0. Lifecycle200,862,296B includes
the same charge. These remain logical/sampled accounting, not physical reclaimed-space proof.

Authorize one normal Rust1.99.1 finite correctness E2E using the previously frozen e566440f...
CLI anddc810c02... example, original099153c0... worker andc14c33d5... runner. Same pinned
ptt5 recovery ZIP,8MiB/96entry/300s outer/240s child. The reviewed new module hash above
is this execution's source identity; historical S3 module pin and closed marker stay intact,
reconstructable from the exact4dc82c... beforeimage. Require34 outcomes,3 full goldens,
24 archive suffix hashes, full recovery and newly protected recycle-retained finalization.
No performance comparison or adoption claim follows from this E2E.

### Native E2E completion and Mac preparation (2026-10-26)

Run `b617bf805118487989980af5c7805941` completed with child/Job/EOF success:
34 outcomes (14 normal,20 expected refusals), all3 full goldens identical to the
prior1.98 run and24 suffixes with manifest SHA
`57f34e63ea849913853d2487008121635d0a5416656101624a5f50fb6eb22b71`.
Recovery ZIP SHA `ba4513ba9a8cd0aaf870ecfcf28e62d4e56a5d07d9e5128da068f8d55324b6c5`.
The89-entry/74-file source and ZIP matched (5,453,487B). Installed Prunlet operation
`7e869c3becec4543a62619740f51cde8` moved the original work root to the Bin once.
Delete-result, finalization, protected complete verification and subsequent Cargo lease
acceptance passed; no purge. Proof SHA
`1815e8b2d2da4e36d29576bd972043c0fe3ecd6f3e38f610376521b0eb68b345`.
Bin payload5,453,487B and7MiB metadata reserve remain charged, plus1MiB probe metadata.
Current module `ebcf49e470049c93d46b0159e400d1f7d71a01cedb68f4abd007eac8d234b86a`
and harness `63df5700789c89774507e9e85cd4dacedc4d0780d7f8d97d1c24f076e9b27ede`
passed90 boundary cases and parser checks. Old schema1 completions remain valid.

The human separately authorized SSH `m3mb14`, native setup/build/E2E/comparison and
isolated official tools (3GiB maximum, Cargo1GiB, no system installation/settings).
The same Windows private ledger explicitly reserved remote ordinary1.5GiB plus
Cargo1GiB (2.5GiB total) at `2026-10-26T07:59:23.5618243Z`.
Mac root is `/Users/szk/Library/Caches/Kagayoi/UnLhaRe/goal-restore-20261019`;
the exact sibling `-bootstrap` holds only the3 setup files, with1MiB reserved inside
ordinary space. These reservations are not actual remote usage or additional quotas.

Actual Mac preparation and supervision self-test passed: timeout including grandchild,
simulated HUP/parent loss, sandbox owned write/stdout/devnull and outside-source write
denial. An actual disconnected owned SSH session caused child group7149 to be killed
and reaped; both supervisor7133 and child were absent afterwards. Journal
`ssh-disconnect-done.json` records `parent lost`, child returncode-9.

First install stopped before executing any installer: its static option check expected
literal flags, while the authenticated official rustc script declares `valopt prefix`
and `opt ldconfig` (script SHA
`1b1ab708c8de4dbfa345cf1ca8fe3a7796c5e8bd91afd14e55489b75c1260535`).
Original started/failed records, manifest/checksum and pinned rustc archive remain.
At that first stop no Rust prefix existed. Corrective admission was limited to this
exact pre-execution state, once, with separate immutable repair records.
The reviewed correction (`47fe5ad1c88d0ae655e83fd29a431bb0f8055986351b03a0f986c8dff3d64c20`,
12 cases passed locally and on Mac) installed rustc and Cargo1.99.1 and verified their
native ARM64 versions. It then stopped before extracting std: the fixed official
std archive has78 members, no links and152,290,621 expanded bytes, exceeding the
profile's120MiB estimate. Its fixed SHA `fe79d6ab5a0321de26463999d8c112b8ad3eafbcbcf822d66a2300b45dde1031`
matched. `install-options-repair-failed.json` preserves the distinct `tar scan bound`
failure; staging is empty and installer components are exactly rustc/cargo.
At this stop actual ordinary404,943,041B plus bootstrap1MiB was charged; Cargo0.
No original failure/start records are removed or reset. A separately reviewed
`finish-verified-tools` stage is limited to this observed component boundary, with
std-only160MiB expansion allowance inside the unchanged ordinary1.5GiB total.
It must authenticate installed rustc/Cargo bytes against their pinned archives and
preflight every remaining fixed archive before invoking another installer.
Mac native builds, E2E and performance remain unverified at this checkpoint.

`finish-verified-tools` subsequently completed on Mac with reviewed setup SHA
`4834f63e0baaaaf4eac94bf4b50f576afcba7648647ba70d5c14158e20f516d4`
(14 cases passed locally, independently and on Mac). Its done record SHA is
`2da3213509f788b61113edf5445a3327b8e129bf9a55df4ba199c4ffdfb88685`.
Installed rustc/Cargo files matched pinned archive manifests byte-for-byte. All
remaining archives passed preflight before additional installation: std152,290,621B,
fmt5,824,923B, clippy13,647,705B,7zip6,314,046B. Native ARM64 versions passed:
rustc/Cargo1.99.1, rustfmt1.10.0, clippy0.1.99,7-Zip26.05. Staging is empty.
Actual root ordinary589,018,566B plus bootstrap1MiB=590,067,142B; Cargo0.
This completes tool preparation only, not the native build, correctness E2E or performance.

Native build input snapshot is `mac-native-source.zip` in the same task keep root:
305,068B, SHA `030eaef48e23004e7902bfe81c0ba28eca15b505252ee59b5d0caa1e43926c3f`.
It contains78 manifest-bound Rust/build/license input files (2,609,912B) plus its
manifest; transfer SHA and every member byte/SHA/type/name were checked. The limited
build selects lib, CLI and `khc_spatial_mdl_e2e`, not other research examples with
external experiment-module paths. Snapshot intentionally excludes `.cargo` and outputs.

Reviewed controller `mac-native-build.py` SHA
`d9b16b49e083bdbb0b76142114c862e8d2a94160bf9354a1097cd9486b0ade22`
binds setup `9c0340155ca450d44f83b62f28eea64100e681bf076eb726114ddac65496522c`.
Independent setup15/controller2 cases passed, with added failure checks preceding code.
The same bootstrap contains only3 files; controller lives inside root/tools. Mac setup15
cases passed after transfer. Start with `/usr/bin/python3 -I -B`; import must not create
bootstrap pycache. Cargo input and ancestor/home configs are checked, source bytes are
verified before/after, fetch has write-only-root sandbox with network, subsequent
Clippy/build stages deny network. Explicit target/compiler/docs/jobs/offline/locked
options preserve the isolated1GiB Cargo area. Budget pre-admission reserves remaining
Cargo capacity plus logs and the5GiB free-space floor. Internal same-Cargo-tree hardlinks
are charged once per pathname after full alias/nlink/size/class agreement and re-stat;
changing/foreign/cross-class aliases are refused after at most3 complete scans.

Windows bridge `run-mac-native-build.ps1` SHA
`3b77ef4d80237f060fe9f3c71830036e457bd57179d843cafbaade9c7706ac26`
uses the shared Cargo lease before remote start and until terminal verification/storage.
Module `ff666fde9d77c61dd8215402ff1a8ccd5acf4a42fe8ec1962933906df7e6af1a`
and harness `83793ab680302db26a2f391d38eabb972409e51642bd516004886d3d55bda3c5`
passed137 checks and independent review. The protected root has a one-time activation
and per-stage intent bound to each immutable started record's full hash. Ledger union
rejects single-record/directory loss, orphan terminal and identity/hash mismatch.
Unknown SSH termination leaves pending and blocks future Cargo/registration; confirmed
same-identity terminal with absent children resolves it. No missing-state auto-repair.

Before first stage starts, the native E2E is being attached to the final build stage
so the same lease/pending proof covers compilation and correctness. Its fixed oracle
is5,645B, SHA `343e08f0e41295e736ffc94d2ab70340228e6e50bacd829a5e72c3b5a4b39d75`,
derived only from the already verified Windowsb617 recovery ZIP. It fixes34 case outcomes,
3 full folded frames and24 archive suffixes; no Mac-produced expectations are substituted.
Configuration SHA `40c47b77f8400112a963d4efb26994bf97fb0ca3690943035071045d6d8ecbe3`
fixes8MiB/96entries,300s global/240s child,1MiB outer-log and64KiB report reserves.
The fixed513,216B ptt5 source and oracle/config have been transferred and SHA verified.

The actual first Mac stage uses controller
`51baf46cb26f441e1148123409a271421bd17944893e9bbd3e2fd68401c56a97`,
setup `9790c77fb4e427247e9c1217c08b18243a31cdcd6e868ff1836ae392bfa59fd1`
(comment-only reconstruction matches9c034...), and E2E script
`60311a84931e505b6b2de2810d31ed2d7c3e60c4ca6af66c1baf59c5a1eda12c`.
The final script passed10 prior-to-fix pure/mock checks and independent review.
Sandboxed inner E2E never sends signals; a live-child failure retains its original
error and fails promptly so the outer supervisor terminates the entire owned group.
Group inspection uses Mac's documented `ps -g <own-pgid> -o pid=,pgid=` with at most
64 rows, rejecting foreign groups, duplicates, missing self or remaining children.
No all-system process inventory is fed through the32KiB child-output limit.

`prepare-source` completed with exit0/children_absent true through the real shared
lease, immutable activation/intent/start/terminal path. All78 snapshot files passed
the Mac name/type/byte/SHA checks. Ordinary charge593,545,838B, Cargo0 at this stage.
The next fetch stage has been started through the same bridge; no comparison timing
or correctness pass is inferred from successful source preparation.

Fetch completed (Cargo45,665,917B). Initial Clippy exited0 after109s but recorded
xcrun cache-write denials outside the root and a rust-objcopy LLVM load/strip warning.
These diagnostics were retained, not treated as a clean native toolchain check.
Local Mac man/otool inspection identified SDKROOT, the real Xcode clang and
`prefix/lib/libLLVM.dylib`; `xcrun_nocache=1` alone still attempted OS-temp writes.
With the exact child-only SDKROOT, dedicated cc shim/PATH and DYLD_LIBRARY_PATH,
both C and Rust compile/link/run probes succeeded with entirely empty compiler output
inside the unchanged sandbox. Probe record SHA
`402f11594060e0739653a95e669df8ac2076493d8e1e2bb304411d7b0a9a13ea`.

A single build-only amendment was registered under the same shared lease at
`2026-10-26T10:29:03.106599Z`; raw spec809B SHA
`11e85de06adf4b318cb64e7986d6c97a86f8c3de87ff93765b35bd5b0e2c84ca`.
It preserves the old3phase records/controller51baf... and authorizes only unstarted
build controller `9bd8d719b7f94305070866a5c84a62ffdb805f2b0bf16599dfc568522b3fddfb`.
Environment profile `4febd21b0ab814a62efb12c006c91ab5c9d4776cdd5c3d8a03e7f8c3213769e3`
binds the fixed old check terminal and native probe, plus cc shim
`4623cf9926461aeba37d195812a5a657db751a921d743ec01ddc4a08a8e92827`.
Windows module `9d011baa2a939b1d9c0c4331d4badabff1a57559e1494766691ca7c96f015774`,
harness `853d094ee9c87b64673b4251f767696482b768f18a2f840f6053a6bad2284fe4`
and bridge `22a2b6d313f9f87b041b8155da8dcd67512b5edd6227bd7c2eacd24e0bfedc31`
passed166 checks and independent review. Public spec uses one bounded64KiB byte
snapshot for SHA/strict UTF8/duplicate-free JSON/type validation, preventing an A/B/A
reopen mismatch. The actual final809B spec passed this same read path before registration.

The corrective native Clippy freshly recompiled unlhare after a recorded build.rs
mtime-only update, byte SHA unchanged. It passed in26.66s, and native Release build
passed in46.42s, with no `warning:` or `error:` anywhere in either complete log.
Native ARM64 CLI2,034,384B SHA
`5338389a94ecad6296fab1686398ef7d01efaf1783fb3fa90e54fa61d0fa9629`;
E2E example1,195,312B SHA
`b4e8d7c5fe5fa87b74c466cacabe4c94baddf80a1717b66629e0012c59e12ff4`.
The combined stage nevertheless FAILED: the final sandboxed `/bin/ps` launch returned
EPERM. Outer supervision confirmed the owned group absent; the failed terminal and
all output remain, and no full E2E pass is claimed. Failed Mac terminal SHA
`1b66fadf5833ad2874738b91b7107ccff9dd906f0b58ab4beb7f936d275ab9b7`.
At exit Cargo255,345,507B and ordinary599,919,962B,total855,265,469B were charged.
Correctness-harness repair is the next step; comparison timing remains unmeasured.

### Mac ps-free correctness and reference-pilot preparation (2026-10-26)

The separate ps-free correctness run `dfadaf35e56a4579b4d8cbd8eccc451b`
passed all34 checks (14normal,20expected refusals), including3complete goldens,
24suffix probes and2restored byte/hash comparisons. The old failed build record
above remains failed. Canonical Mac terminal10,955B SHA
`0f9b1a1cb744775b64c7cdcbb485efebb2e5f4ba2cf0d58c99ee903255676299`
and report7,203B SHA
`5a857c69a46922c23477fe95904ab660e08fa55319008a4e106c8d3e27d3eebb`
were independently reread before sealing the Windows cleanup. Recovery ZIP SHA
`442250176ae8f636f4325345173d2f37274292a7b697db4bc7c0dad1500e2001`.
Installed Prunlet preview/delete/finalize completed for the exact Windows run;
operation `e34d9c6331ee49209dca4c409def32f1`. Schema6 retains18,158B in Bin and
7,340,032B metadata charged, reclaim0. Completed receipt validation also requires
the private terminal seal;205 lifecycle checks and independent review passed.

The next Mac pilot uses known Canterbury11 strictly as training/reference data:
11files,2,810,784B, canonical input manifest
`bb63b0d70713c9aefa681347eaf99fb891d59f45923e009ad0deadc9ec9fc438`.
The bounded transport ZIP2,811,966B SHA
`29d1f681371d50819a904a9fc4639c276268fa631b709f9b4afe9398857d7b71`
and manifest1,988B SHA
`458a2048459bbcae07a771c072d5e387af910c9916545919e42cbb3bcfbb87af`
are retained in the same task keep root. Every payload matched the earlier fixed
training profile before repackaging. This does not establish unseen performance
or satisfy the overall superiority goal.

Native measurement plumbing was calibrated with a C no-op, not a codec trial:
direct posix_spawn/wait4 and native `/usr/bin/time -l` both reported1,769,472RSS
bytes. No no-op duration is subtracted from future CLI timings. Calibration SHA
`30a4ec4a6c62c854599776592a26e3a620cce79e7456b2d859fd4bdc60be3b10`.
The read-only native system-metrics helper reports Mach CPU ticks,14logicalCPUs,
thermal state and AC power; binary SHA
`31955203a22b4128b956e86daa4bffb653e513bb31682d63a9b8b5941df8d5ba`.
Codec comparative timing remains unmeasured at this preparation checkpoint.

The bounded Mac reference protocol is now frozen:2,082B SHA
`960a6c8d732e24a3a1e828585327284b815cb1e62b83c60e3daf1105c9ccdbf4`.
It binds endpoint
`a73c73df659adac86160661c53e48098873c298c4e94489773b8169d8ac421a4`,
measurement helper
`0867ef2f84192c14f839a90fb731813f0f20edb0ec10e59fc01dec3a273dc855`
and7-Zip26.05 binary
`8e495531e1b2b8cb169ca583493922d4ab386007756418c15b95f07f642c35fb`.
Known Canterbury11 is compared with portfolio-trial,7z/LZMA2 mx9/8MiB/fb273
and7z/PPMd mx9/64MiB/order16. Each uses one encode/decode worker, one warmup
and six order-balanced measured rounds; all21restores require complete SHA matches.
The pilot retains160MiB/512remote entries within the existing shared reservation;
Windows receives reports only within8MiB/96entries. Each encode/decode helper has
60s/20s outer-supervisor deadlines; the1700s campaign reserves10s for finalization.
RSS128MiB and CPU-time/wall1.2 are post-measurement eligibility, not OS quotas.
Native helper tests5/5 and endpoint tests7/7 passed. Actual CLI-version plumbing
also passed with the owned group absent; proof SHA
`1ffd126828c9a1ee0f4a59bdea2d416af3249d5156b99903856e7d6a5773961a`.
Windows256pure lifecycle checks preserve all205earlier checks, and the native
protocol/full-report shapes passed the Windows validators. The latter full-report
check used synthetic values solely for schema integration, not codec measurements.
Mac transfer pins and all11payload hashes passed before any pilot codec invocation.

The actual reference run `feed87d5326f4f189cfbcb5818a7ea36` is now CLOSED STOPPED,
not a completed six-round benchmark. It produced7fully restored encode/decode pairs:
the3warmups, one complete measured ABC round, and the next LZMA2 pair. That final
decode observed CPU tick deltas[10,3,26,0], i.e.33.333333%busy, above the fixed30%
interval limit; thermal0, AC power and resource limits otherwise held. No quiet-load
retry, reopening, changed threshold or post-hoc reduction of required rounds is allowed.

The first eligible measured round, with CLI launch/scheduling included, was:

| Method | Archive bytes | Encode seconds | Decode seconds | Encode RSS MiB | Decode RSS MiB |
| --- | ---: | ---: | ---: | ---: | ---: |
| KHC portfolio-trial | 450309 | 0.940007250 | 0.122470375 | 37.890625 | 10.5 |
| 7z/LZMA2 | 480631 | 0.677683833 | 0.019938916 | 36.734375 | 7.0 |
| 7z/PPMd | 574785 | 0.171064458 | 0.192222375 | 47.156250 | 45.843750 |

These are individual observations, not medians or statistical performance claims.
All sizes within each method agreed across its observed repetitions. Relative to
this LZMA2 observation KHC was6.30879%smaller, with1.38709times encode and6.14228times
decode wall time. The pilot establishes neither unseen/general superiority nor Goal9.

Canonical Mac terminal14,351B SHA
`ff13dcf396a3d0ebadb306d457d0e0a361aeb208cfa7a2775506dc5fc5a0715c`
was independently reread through the pinned endpoint before private sealing;
report9,754B SHA
`b0316a7387b048908ad5bef664520fd720e487000f389c0ce05c18e15f49992b`.
The raw report and receipt remain in the run's recovery ZIP SHA
`177146b26939d15b40d24ed44915245d1a5049fc0449296a5d27320d2d991c66`.
Prunlet operation `1771473f9de0485c82c5b60af3bdf6b2` completed preview/delete/verify/
finalize for the exact original Windows root; proof SHA
`a297f5dbaa9c5615896b9b3e61036b9ee2c88f1fca0acfc3fa487dcf371d3aaf`.
The root is absent, while24,105B Bin payload plus7,340,032B metadata stay charged;
reclaimed0. Mac data and closed-run diagnostics remain within the same approved root.
The next investigation concerns the real decode-path cost, without weakening full
restoration, corruption checks, publication safety or the closed campaign criteria.

### CPU observation calibration, without codec execution (2026-10-26)

The separate one-shot diagnostic `mac-cpu-observation-calibration-20261026`
completed in16.845871458s, with3entry baseline samples and36fixed, rotating
diagnostic samples. It executed only metrics, `/usr/bin/true` and the pinned CLI's
`--version`; it did not encode/decode inputs or reopen the stopped comparison.
Script SHA `cb5ef0c6f4b4eb10f7f8c0ca17bc49620f815d29723e28ed386410bb9ae617b0`.
Nine pre-implementation pure tests passed on Windows and native Mac; independent review passed.
Frozen setup9790... and measurement helper0867... were unchanged.

| Mode (6samples each) | Unobservable zero-tick samples | Available CPU range % | Samples above30% |
| --- | ---: | ---: | ---: |
| Adjacent observations, no command | 1 | 0–50 | 1 |
| true | 1 | 0–36.364 | 1 |
| CLI --version | 2 | 10–36.364 | 2 |
| Idle100ms | 3 | 6.875–19.512 | 0 |
| Idle1s | 0 | 7.001–9.309 | 0 |
| CLI --version plus1s observation window | 0 | 7.546–8.989 | 0 |

Each baseline independently passed the15%entry criterion:9.104%,7.279%,9.760%.
All observations had thermal0 and AC=true. Zero tick deltas are null/unobservable,
not0% estimates. CPU values above30% are diagnostic observations, not benchmark
eligibility decisions. Two observer calls together had median wall cost about
9.7–11.9ms depending on mode. Native snapshot timestamps are unavailable; the raw
data retain wrapper lower/upper time brackets and separate CLI spawn-to-wait4 time.
The extended window starts after the before-observe call returns; no duration is
subtracted from the CLI time. These findings support prospective observation-method
work. They do not prove that the earlier33.333%was background load or measurement
error, and do not reclassify that closed benchmark or relax its gates.

Raw report27,934B SHA
`0b9dc292118c8c66d3e923445045b134acb613cd68e719cdb95dd86ef3f22b95`
and terminal884B SHA
`ad015495e3f44386dedb834bb1e5c1e944765a29ee6e3c750a215f3077f77178`
were copied byte-exactly to the existing task keep root as
`mac-cpu-observation-calibration-report.json` and `...-terminal.json`.
The Mac report/progress remain in the same task root. Actual RUN54,351B/4entries
plus147,456B/3journal-entry reservation charge201,807B/7entries, within1MiB/16.
Supervisor log limit16KiB applies only to this imported diagnostic module instance;
child TEMP points into RUN. Runtime100s reserves room for Supervisor cleanup and
finalization;120s is a final elapsed check, not an independent OS watchdog.
The terminal confirms the owned process group absent and all dependency/closed-run
SHA values unchanged. This is calibration evidence, not a new codec performance result.

A future continuous CPU observer must be registered as a new measurement criterion:
a1s average and the former per-call interval do not detect the same load, even if
the numeric30%threshold is unchanged. No new criterion applies retrospectively.
Before unseen evaluation, fix cadence, conservative time-bracket coverage/sample IDs,
all-overlapping-window decisions, entry windows and unobservable/stop rules; never
extend or select windows in response to observed CPU values. The new schema and its
evaluation data/superiority criteria remain to be implemented and preregistered.

### Prospective candidate binding and input metadata (2026-10-26 UTC)

Before selecting new holdout payloads, the existing Mac candidate was rebound by
SHA and all78source files were verified against the pinned source ZIP manifest.
Source ZIP030e... and native CLI5338... were unchanged. Mac UTC
`2026-10-26T14:52:52.646428+00:00` agreed with the independent clock reading
`2026-10-26 14:52:51 UTC`. The source-only binding is retained as
`mac-candidate-freeze-v1.json`,1,063B SHA
`75cf6c2a918005ab29017e1115a39966b623df6eaa75e66800b33a8238553c10`.
It is not an evaluation preregistration. Its new-public-data boundary is
`2026-10-26T14:54:52.646Z`; publication after that time is necessary, not sufficient,
for a proposed temporal holdout. Existing or uncertain corpora remain non-holdout
evidence. Any codec change invalidates this candidate binding.

Only public metadata was examined for a prospective fresh operational-record input.
The official [AWC Data API](https://aviationweather.gov/data/api/) documents bulk
METAR CSV/XML gzip caches updated once per minute and recommends caches for larger
queries. The [NWS disclaimer](https://www.weather.gov/disclaimer) describes its web
information as public domain unless otherwise noted. These are input-provenance
leads, not a selected corpus or proof of unseen content. The current cycle-directory
metadata did not itself establish a post-binding payload; no weather payload was
downloaded or measured. Format, observation/publication dates, exact hashes, prior
tuning overlap and applicable notices still require prospective selection checks.

The same topic was searched through Plumivox public X search in Japanese
(`METAR 公開データ`) and English (`NOAA METAR data`),each1API request,scope=all,
`2026-09-26T00:00:00Z` to `2026-10-26T14:54:52Z`. Both returned0posts and no next
page, with completeSearch=false. No X claim was adopted; zero returned posts is not
evidence of absence. Only the official metadata above informed the candidate lead.

### Continuous observer primitive and failed closure check (2026-10-27 JST)

Primitive `mac-continuous-cpu-observer.py` SHA
`416687bc9460f0264e4f0620cce34a257c7647916fa1a71ccf66a86750fa3ffd`
passed16先行pure cases; its no-codec OS driver
`mac-continuous-observer-e2e.py` SHA
`cd690ce8799436739dbcafef2ab3f85ecc2ad40f3ea12030b5d201416e40015a`
passed5先行pure cases. Both sets also passed on native Mac before execution.
The primitive enforces1250ms cadence,≤50ms start lateness,≤200ms captures,
1000–1500ms native-snapshot brackets, three entry windows≤15%then runtime≤30%,
thermal0/AC, consecutive IDs and all possible overlapping-window event coverage.
An active end equal to the last capture start remains pending; only the normally
completed, pre-fixed finite timeline permits final equality. Same-process monotonic
timestamps avoid assuming that Python3.9 clocks share an epoch across processes.

The one-shot `mac-continuous-observer-e2e-20261027` is CLOSED FAILED, not a full OS
E2E pass. Normal phase passed10captures and6CLI-version events across window IDs
`[4],[4,5],[5],[6],[7],[8]`. Maximum observed capture start lateness10.048ms,
capture duration8.988042ms, window lower minimum1240.978625ms and upper maximum
1266.454542ms met the pre-fixed conditions. Entry CPU10.256%,12.278%,9.309%;
maximum runtime window9.609%. Its raw report SHA is
`3958bf18d0071bab4d9f074e8d93df58fe2a88fd82ea10020ea18f189d020c68`.

Fault phase saved the planned capture-ID4 injection,4prior points and an unfinished
event: sleep45 fixture52372, helper52361, spawn4010066625ns, wait4-entry marker
4010947333ns, callback fault5010200791ns. However, outer group handling returned
`[Errno 1] Operation not permitted`; the controller ended after17.125371125s with
`failed-no-codec-e2e`. Kill/reap completion and the actual helper exit status were
not established by that failed path. The later15:31:58.325387UTC inspection found
both PIDs absent (getpgid/signal0 ESRCH), which does not prove successful cleanup:
natural sleep45 expiry remains possible. No signal policy or old result was changed.

The raw terminal, normal/fault data and late inspection are preserved byte-exactly
in `mac-continuous-observer-e2e-20261027.zip`,15,824B SHA
`34d8d9eab90b0615017355b5c725fa79bb2af2574ffe10de90fba7103b088bab`;
terminal SHA `327ee05b0613c02853a11b27034a44d6b3178ea93672ebbd119e36b726dc5187`.
The next separate root-cause probe compares original-sandbox and no-sandbox controls
with a fixed sleep2 fixture, records live/reaped identities and each syscall errno,
and does not retry/reopen this failed check or run codecs. A control success alone
cannot authorize a sandboxed benchmark. Goal9 and the full goal remain unachieved.

The separate signal-boundary probe then completed its two fixed conditions in
1.032923666s. Probe source SHA
`17c651b16a55f29f5352841f9eca1a95eb64ee1363c2dcc2267f0caf000c978b`
and10pre-implementation pure tests passed locally and on Mac. Its raw report and
terminal were byte-identical,11,484B SHA
`8c7777398e3fdcdedddf487f744b48fa5757e71a643430997f87bb8048bc4cef`.
One copy is retained as `mac-signal-boundary-probe-20261027.json` in the task keep root.

Both original-sandbox and no-sandbox controls verified helper exit70/reap,
helper/fixture process UID501 and common PGID, then group SIGKILL delivery success
and fixture ESRCH about110ms later. Parent-clock Popen-start-to-kill upper bounds
on fixture age were145.521375ms/142.565792ms, below the fixed sleep2 duration.
PID fallback was unused. All live/reaped group checks succeeded except the expected
ESRCH for the already reaped helper. This probe did not reproduce EPERM and does not
identify its cause or turn the earlier failed E2E into a pass. Child and parent
monotonic timestamps are separate; no cross-process subtraction was used.

The prospective repair is therefore error handling, not a signal-policy change:
preserve the primary outcome separately from signal delivery and closure; treat
EPERM as uncertain, require direct-child reap plus deadline-bounded group0 ESRCH,
and forbid further work when closure cannot be proved. Frozen setup9790 and the
failed driverCD69 remain unchanged. A new finite supervisor and separately bound
v2 no-codec check must pass before this mechanism is used for new codec evaluation.

The separately bound v2 check uses supervisor SHA
`51a0dcca109e302543b9a643f7d255813163cae64c4c0404dc74c7b9b5932b30`
and driver SHA `afd0da6a444c469606b1e568ad85fe6cabfad63c9ab2bc2ab973c89a8c6627e3`.
Its 17 supervisor and 6 driver pure checks passed on Windows before native execution.
Retained child output is capped at16KiB even when a single read exceeds that limit.
The new one-shot prefix is `mac-continuous-observer-e2e-v2-20261027` inside the
existing Mac root. It preserves the original normal/fault observation schedule,
requires primary exit0/70 independently of closure, and persists each raw closure
proof. Its cap is2MiB/64entries including journal reservation, with60s runtime and
80s final elapsed bound. This is measurement-infrastructure validation only;
it does not run compression, select holdout payloads, or authorize a superiority claim.

After Mac reconnection, the fixed setup admitted ordinary634,511,505B plus
Cargo255,345,507B (total889,857,012B), and CLI5338 remained byte-identical.
The new slots and one-shot markers were absent before transfer. Both pure suites
also passed natively (17+6). Independent source review found no execution blocker.
The v2 then completed both phases in17.409095833s, with14,639B/13entries in its run
and178,479B/17entries charged including reservation. Normal exit0 and fault exit70
were verified separately from closure. Normal closure observed kill ESRCH (no signal
delivery); fault closure delivered SIGKILL, observed the group live, then ESRCH
60.082542ms after the wait started. Helper PIDs were58468/58519; fault fixture58527.
The six normal event-window sets were `[4],[4,5],[5],[6],[7],[8]`.

All ten raw files and their hash manifest are retained byte-exactly in
`mac-continuous-observer-e2e-v2-20261027.zip`,7,365B, SHA
`2abf37e33832adef1bcdce176fac9b52a5f944cad3a3daca87b6d753fc53efbe`.
The terminal SHA is
`e30e1bcee8ecab6358e3cf6d73483f97393575fe934b75df2ec96c8f4eaf9478`.
The parent independently checked archive member hashes, recomputed normal/fault
validators and both closure proofs from this local copy. This establishes this
v2 execution only; it neither reproduces the old EPERM cause nor changes the old
failed E2E or stopped reference benchmark. New comparison criteria still require
prospective registration before any further codec measurements.

Independent read-only review of the local proof ZIP also recomputed all10 member
hashes, both closure sequences and CPU tick deltas. Normal entry windows peaked at
11.0538% and runtime windows at17.5287%; fault entry windows peaked at12.8087%.
No contradictory evidence or blocking issue was found for this infrastructure
check. Further evaluation still needs its own prospectively fixed protocol.

The next implementation is a separate continuous Canterbury training-reference
endpoint, not a reopening of the stopped reference. Its proposed fixed schedule
is warmup ABC followed by ABC/BCA/CAB/ACB/CBA/BAC:21 complete restore-checked pairs,
42 CLI invocations, and64 fixed-cadence captures. Entry3 windows must meet15%,
remaining windows30%, all thermal0/AC. Completion requires the exact full schedule,
all restored hashes, and the last event ending strictly before capture63 starts.
The existing per-CLI60s/20s,128MiB and CPU/wall1.2 eligibility limits stay fixed.
The new campaign budget is90s, outer-helper100s, final120s; these are finite
eligibility/closure budgets, not a hard kernel/I/O watchdog guarantee.

Independent planning review required full count/order validation, strict final
capture coverage, and bounded split evidence. The implementation therefore uses
individual capture/CLI/pair JSON evidence (64+42+21 files), each at most64KiB;
a report at most32KiB binds their exact names, lengths and hashes, and the terminal
at most64KiB embeds the report and closure hash. The existing160MiB/512entry remote
cap includes journal reservation. This plan is not an executable registration;
the finished endpoint, pure validators, Windows lifecycle binding and exact
protocol must be reviewed and frozen before transfer or codec execution.

The endpoint implementation is now present as
`mac-canterbury-continuous-reference.py`,32,351B SHA
`4092605d8384666954dd00994a0145d4e81656096d617a957a1512fb9bc34a42`;
its17 pre-implementation pure checks pass on Windows. An independent review found
a failed-terminal recovery defect: report bytes could survive a report-validation
failure and make the failed receipt fail its own validator. The campaign catch now
clears embedded report bytes while preserving the original report file; a regression
executes that campaign failure path with memory I/O. This endpoint has not been
transferred to Mac or used to execute codecs.

Windows wrapper/private-seal integration remains necessary. Keep127 raw JSON
members in one bounded ZIP and validate through an in-memory reader so the fixed
8MiB/96entry Windows budget is respected. Preserve a separate read-only proof
retrieval path: normal `--inspect` deliberately rechecks current dependencies first,
so dependency corruption may prevent inspection of an otherwise saved failed receipt.
Do not launch the new endpoint until these bindings and exact protocol are ready.

The bounded proof helper `mac-continuous-reference-proof.py` has source SHA
`24a6b9d575820be99ba92fac913dc5a36ec712f7efe6dfa905e4cc66bc748cd5`.
Eight pre-implementation memory-only checks pass; independent read-only review found
no integration blocker. Collection modes use only the standard library and fixed
Mac paths, so dependency corruption does not require re-running the campaign.
Verification loads endpoint4092 and its frozen dependencies locally, rejects unknown
or duplicate ZIP names, links and encryption, and caps each member at64KiB, expanded
total at2MiB and ZIP at1MiB. It never extracts members. Only the parent-local
verification result can authorize closure sealing; a remote summary or successful
`--read-terminal` call is not such proof.

The exact canonical protocol was saved CreateNew at the current task keep root as
`mac-canterbury-continuous-reference-protocol.json`,3,055B SHA
`3df9f796fcadac5779128a495757ec2646d082a8087bf39d7f589e6ed481ac9b`.
Its fixed-schema verification passed. Windows remains8MiB/96entries with a new180s
deadline. Before any transfer, Mac admission including the160MiB prospective reserve
passed at ordinary634,578,548B plus Cargo255,345,507B, total889,924,055B; all new
endpoint/helper/protocol/run/start/terminal slots were absent. The passed continuous
E2E terminal still hashed to `e30e1bcee8ecab6358e3cf6d73483f97393575fe934b75df2ec96c8f4eaf9478`.
The Windows wrapper/private-seal implementation is still under verification; this
protocol freeze alone does not mean the comparison has started or passed.

The Windows integration now dispatches reference-v1 and continuous-reference-v1
through fixed worker/protocol-path/timeout pairs, with no unknown-type fallback.
Module SHA `31f148ee23ae930077114cc69ec8807e448579f7938cd308e05f1c09e277b84e`,
runner SHA `d56355d39625c2fdc324786f3a01707f59910942be24648cb377ece7cdcb2681`,
and new worker SHA `7d88a902702458f263982b6a48ea44827baae8713483614893ba3a64454b4d8b`
passed independent read-only review. Parent re-execution passed41 new and256 old
pure checks plus the actual PS worker's protocol-only admission. New seals keep a
bounded private ZIP copy and revalidate it after work cleanup; copying must finish
with matching bytes before sealing. Partial or different copies are not resumed.

After source-only transfer, Mac ran17 endpoint and8 proof-helper pure checks
successfully. Endpoint4092, helper24a6 and protocol3df9 hashes matched the local pins.
The actual fixed SSH helper call for an absent terminal returned exit1,0stdout bytes
and948stderr bytes. The parent initially tried to inspect a nonexistent `Error`
property in the returned DTO; correcting the observation to its actual `ErrorBytes`
field confirmed the bounded rejection. Both calls were read-only, not campaign
attempts. A separate state inspection confirmed that the new run/start/terminal
were still absent. The isolated real-file storage-boundary E2E remains required
before the one-shot codec comparison.

### Continuous Canterbury reference completed (2026-10-27 JST)

The isolated real-file storage E2E passed13 checks. It exercised actual Confirm,
private ZIP copy,12-field seal persistence, registration/cleanup-seal reread,
closed-failed fallback, unknown-closure refusal, loss of work-ZIP access, private
ZIP tampering rejection and reuse of a completed copy after a pre-seal interruption.
Only fixture state/ACL/mutex/SSH boundaries and the production-probe presence check
were replaced. No synthetic result was written to the production private state.
Parent read-only revalidation passed11 checks with0writes. Test source SHA
`3682049a0c0b6868e77c675a30f6e54a500c4f4efeb216ed61bfcba2526a77db`.
The retained two-root fixture (725,312B/79entries) was preserved in
`continuous-reference-storage-e2e-20261027.zip`,484,161B SHA
`ed0732605b3a1455039a729c33d6e27c589caa3da81fe8d9f1c3061dfbf06ced`.
Installed Prunlet operation `0db5566a2e404c9b8fb1c66bc008c367` then recycled
only those two verified fixture roots. Both original roots are absent; Bin payload
is retained, not reclaimed. The proof archive and delete receipts remain in keep.

The one-shot production reference run `d90335da8b8b4e979239fe1b87cea17a`
completed all64 captures,42 CLI invocations and21 fully restored pairs. All21
restored manifests matched11 files/2,810,784B and the pinned input manifest.
Entry CPU peaked at8.4824004616%, runtime windows at16.7045454545%; all captures
reported thermal0/AC. Relative to the common helper epoch, the last event ended
at18.975308875s and the last capture started at78.7600155s, satisfying strict
coverage. Native total79.997883083s, charged72,666,492B/420entries.
All fixed timing, RSS, CPU/wall and storage eligibility checks passed.

Warmup ABC is excluded below; each method has6 measured observations. Times are
medians; RSS is the maximum observed peak over those6 invocations, in bytes.

| Method | Complete archive bytes | Encode seconds | Decode seconds | Encode peak RSS | Decode peak RSS |
| --- | ---: | ---: | ---: | ---: | ---: |
| KHC portfolio-trial |450309|0.9464276455|0.1216197085|46809088|11042816|
|7-Zip26.05 LZMA2 mx9/d8m/fb273,1thread|480631|0.6746091250|0.0187803750|38551552|7356416|
|7-Zip26.05 PPMd mx9/mem64m/o16,1thread|574785|0.1731397295|0.1839060835|49430528|48087040|

Each method produced an invariant archive length. Compared within each measured
round, the median KHC/LZMA2 time ratio was1.4052052962 for encode and6.4483855226
for decode. KHC was6.3087899% smaller in complete archive bytes. These results
confirm a size/speed tradeoff on known training data, not general or unseen-data
superiority. Goal9 and the full goal remain unachieved. No criterion was changed
after measurement, and neither the old stopped reference nor old EPERM failure
was reclassified or reopened.

The private proof ZIP is75,293B SHA
`595fd4fe73fb4ff2c5146062489ec2dadb0c9a33e4acf11a5c5775cf45808daf`,
at `storage-lifecycle/recycle-v6/mac-reference-d90335da8b8b4e979239fe1b87cea17a-continuous-proof.zip`.
Terminal26,068B SHA `88bcfebefe228162fe12c4434d0a6cf493d7d0b8c8f01b6ed6a745c2774a370e`;
report18,149B SHA `36007b310559e728004f1efd009718007d823e4cecccb8d4af26d940cedcde97`.
Parent recomputed all127 raw references, CPU/closure and metrics, then used the
actual Confirm path to reread the canonical terminal over SSH, rehash retained Mac
archives/decoded outputs, copy/revalidate the private proof and seal it. Independent
read-only review recomputed the same evidence and6-observation summaries using
only the private copy and found no contradictory result.

The registered Windows work root `run-1d751107355f4d0ab0008b19bd05376e`
was closed through installed Prunlet preview/validation/delete/validation/finalize.
Operation `69ed3ba233024cbbb3fd03a9252e3466`; proof SHA
`341d89cf121da728fdf37d2c285972e706b7bdfd2123869e80299b17bf0b9033`.
Completed receipts were verified after original-root removal; disposition is
recycle-retained, reclaimed0, retained payload119,510B and reserved metadata7,340,032B.
Recovery ZIP SHA `3be3ad7117b078336a43927942a4539720dae5ef5c004fc2c09a7ab238328eb6`.
The sealed proof remains verifiable without the original Windows work root.

### Decode diagnosis after the completed reference

The six measured KHC decodes have median wall0.1216197085s, median user0.061338s,
median system0.010217s and median CPU/wall0.5837400506. Per-observation wall minus
user/system CPU lies in0.0479925..0.052982708s. LZMA2 has median user0.014654s,
system0.002382s and CPU/wall0.9085873791, with wall-minus-CPU0.001459792..0.002135292s.
These are reanalyses of the sealed raw metrics, not new timing runs. The difference
does not identify fsync, I/O or scheduling as its cause.

The current local main/operation/khc/pipeline/spatial/block sources were compared
with source ZIP030e's manifest and match. CLI KhcExtract calls extract_archive,
which allows pipeline selection, but pipeline eligibility is restricted to archive
revisions4/5 and record/G32 families. The measured portfolio's KHC1BLK/KCS1BLK
families instead use serial process. Do not attribute this reference to pipeline
workers or use the pre-port CompactTree phase example as the measured decoder.

The next proposed single-candidate diagnostic samples one extraction of the frozen
CLI with installed `/usr/bin/sample`, not a new comparison campaign. Native help
confirmed PID/duration/interval and `-mayDie -file` options. Planning review requires
holding the spawned CLI PID unreaped until sample finishes, preventing PID reuse;
then wait4 targets exactly that PID. Output PID/name/executable and usable stack
samples must be checked independently of sampler exit0. Empty/late/denied sampling
is inconclusive, without retries or permission expansion. Its spawn-to-wait4 includes
profiler completion wait and must not be compared with the reference timing.
Fixed prospective bounds are8MiB/64entries including journal reserve,8 observer
captures with unchanged15%/30%/thermal0/AC gates, helper15s/runtime20s/final40s.
Only the helper's own child PID is sampled; the existing source, CLI and archive
pins stay unchanged. No Rust change or speed-improvement claim follows from this
plan alone. It is a direct Mac bounded diagnostic, like the earlier observer E2E,
and does not reopen any closed comparison run.

The single sampling diagnostic was implemented as `mac-khc-decode-sample.py`,
21,130B SHA `85a8bfff922606ec706dea3f77fa57f1d8c723cdb686c19c852886e1aeaa3cd1`.
Nine pre-implementation checks passed on Windows and natively on Mac; independent
source review found no execution blocker. Sampler stdout/stderr16KiB are retained
output/eligibility limits, not a streaming receive-memory bound (`communicate` is
used for the fixed short-lived system tool). Transfer hashes matched before use.

That one attempt ended `inconclusive`, without a retry. Tool SHA
`0527abd95ea1c5a2885489e0d6a76e06c69b66b8a69c7eab4f9276688815791b`
returned0 but wrote no sample.txt; stderr reported `pid_for_task` error5 and
"Sampling process0". The owned CLI PID68436 was retained until sampler completion,
then reaped. No valid stack samples were obtained. This evidence does not identify
whether target termination, attach restrictions or another condition caused the
failure, and does not justify changing synchronization or permissions.

Restoration of all11 files matched2,810,784B and the pinned manifest. All8 captures
were valid, with maximum CPU8.7779690189%, thermal0 and AC. Helper PID67359 exited0,
wait and group ESRCH were verified, and no secondary closure error occurred.
The native diagnostic elapsed17.936100208s and charged2,952,511B/35entries.
Those times include profiler completion wait and are not comparable speed results.

All19 raw proof members and their manifest are preserved as
`mac-khc-decode-sample-20261027.zip`,10,051B SHA
`96e3d3c7e938cd8a8158a44bb4650d78e08387ad46fa0c887aa89c2d61a7ff2d`;
terminal SHA `8d41914b32682fef47b30168c0e44bb59581ad72239e884072054352b23db1c3`.
Parent and independent read-only review recomputed the proof hashes, observation,
closure and inconclusive classification. The diagnostic is closed as inconclusive;
the old reference/source/CLI/Goal9 status is unchanged.

After proof preservation, only the diagnostic's decoded clone was removed: all11
paths were resolved beneath the exact diagnostic root, checked for user ownership,
regular single-link type, exact file set, length and SHA before unlink/rmdir. This
removed2,810,784 logical bytes; original archive and raw diagnostic remain. Receipt
counts above describe the completed diagnostic before that cleanup and are not
rewritten. Next investigation should use a separately identified instrumented build
with a few coarse phase timers, preserving output/sync behavior, collecting timings
in memory and writing them once. It remains a diagnosis, not a speed-improvement
claim or a reopening of this sampler attempt.

### 2026-10-27: separate coarse decode-phase build, first attempt failed closed

After the user reported the Mac restart complete, SSH and the retained task root
were available. The diagnostic build had no native start/terminal, source namespace
or target before this attempt. The original measured source, CLI and reference
remain bound to their existing hashes; this is a noncomparative diagnostic build.

The formatted diagnostic source ZIP is 304,889B, SHA
`1ffe78d045d85e8919fddc166a4a97c997b88ee70fba5ca8a0df20be447c7f55`,
with 80 source records and manifest SHA
`5bfea92de150219d371906813cba9db9471e9de21e7155951b950fd15857ebc5`.
It adds coarse inclusive timers and an example, retaining the baseline codec and
output/sync behavior. The initial read-only preflight refused the system SDK
because the private-work guard rejected root:admin mode 0775 on `/Applications`.
No build started under that controller. Its controller `e94e5c4e…fbc00` and
protocol `1abcb0fb…f04d` are retained under SHA-named files in the existing keep
root. OS permissions were not changed.

The corrected controller SHA is
`da3ba8ba569bd4335776b9276ce1eb42cea4412ba4aa65e77545d59ebfec2cbc`;
protocol SHA is
`64f6aae8c18c83f5f966462c96e1d4ecc3bb34af0a2f114b9844c129539f0088`.
The narrowly scoped read-only Xcode validator passed 18 pure tests and independent
review; the gateway passed 124 pure checks. Native read-only input/admission
preflight passed, then `run-serial-cargo.ps1 -MacDecodeDiagnostic` launched the
first native build within the existing quotas and fixed 300s Cargo interval.

That attempt **failed**, with no diagnostic binary SHA: the live capacity guard
encountered `FileNotFoundError` on the compiler's transient
`release/deps/syn-20c26f012039d0b0.syn.7a5861d6d140e75c-cgu.15.rcgu.o`.
Native runtime was 8.706200875s and the Cargo supervised interval 6.746337125s.
The supervisor killed and reaped its own process group, then obtained ESRCH;
closure SHA is
`d12c7079556b9f44e5e0e952847040f9a467a380a977badf9102669ecc7f91a6`.
Postchecks passed. The private `mac-decode-diagnostic.started.json` and terminal
seal preserve raw protocol/receipt bytes and were reread through the native
verifier. The used controller and protocol are also retained as
`mac-decode-phase-build-da3ba8ba.py` and
`mac-decode-phase-build-protocol-64f6aae8.json` in the existing keep root.

This is not a compiler success, a 27-phase measurement or an 11-file output-SHA
E2E result. The once-only failed attempt must not be reopened or overwritten.
Before a further build, investigate transient-file handling in the live quota
scan, preserve historical verifier bindings, and account for the existing target
in the same aggregate budget. No same-condition retry or new-target quota escape
was performed. Previous comparison results and Goal9 status remain unchanged.

The failed attempt's verifier and three fixed dependencies were preserved in the
keep root under `mac-decode-verifier-da3ba8ba569bd4335776b9276ce1eb42cea4412ba4aa65e77545d59ebfec2cbc/`
(97,601 bytes total). The Windows lifecycle now selects that bundle only for the
fixed historical controller SHA and checks every file and SHA before execution.
The historical-ledger check independently revalidated the original protocol,
receipt and closure and confirmed the private start and terminal seal hashes were
unchanged; 136 diagnostic, 256 lifecycle and 41 reference contract checks passed.
This preserves verification, not an authorization to reopen the failed attempt.

After the failed build was closed, read-only native accounting reported 710,149,592
ordinary bytes including the bootstrap reserve, 271,009,833 Cargo bytes and
15,664,326 bytes within the diagnostic target. The 80 derived source files passed
content verification, the original CLI matched its pin, and the diagnostic binary
was absent. Existing target bytes remain included in all later limits.

The corrected one-walk diagnostic storage snapshot was frozen at SHA
`b99b4338cc3253181402b215fa826230d6284a9044ba9520efc04af1d0253806`.
Seventeen local cases passed, including real NTFS rename and hardlink operations;
Windows UID and Unix mode were injected, not native Mac permission evidence.
Independent review found no required correction to the accounting. Its three
bounded attempts discard a whole snapshot on fixed-target races; the design is
not an atomic filesystem snapshot or an OS-enforced hard quota.

A separately identified single additional attempt is bound to the first raw
failure and closure, same ROOT/source/target and existing limits. The reviewed
retry controller SHA is
`771443623c9255e7cfd1ef2272dd265035aa38c3c5a903c245b63361db8eaafe`;
the canonical amendment SHA is
`f2a4979ed0f796b98876a324734998329eb40255b8593350ee439165873ae46e`.
Nine controller pure checks passed; independent review verified the 13-second
process-group recovery reservation and the pre-persistence deadline handling.
The controller, snapshot and amendment were transferred to the authorized Mac;
native read-only preflight revalidated the old raw evidence, 80 source files,
absent binary and admission, reporting 710,182,403 ordinary bytes including
bootstrap, 271,009,833 Cargo bytes and 15,664,326 target bytes. No retry start
or terminal was created by preflight.

The Windows retry gateway was integrated with the real old proof and amendment.
Independent review identified a leaf reparse-point race and unconfirmed verifier
exit handling; both were corrected and re-reviewed. The parent reran 219 contract
checks, including historical evidence and quarantine behavior; 256 lifecycle and
41 reference checks passed independently during implementation. Real file symlink
creation was denied by Windows permissions and remains untested; real junction,
hardlink and directory refusal were checked separately. Shared upper-ancestor
replacement and absolute ACL isolation remain outside the bundle lease guarantee.

The fixed gateway then executed the single additional native build. It completed
normally in 56.623948959s, with a 53.484921333s supervised Cargo interval, source
and tool postchecks, child wait and process-group closure. Raw retry receipt SHA is
`b5e6efbefc39bafa9f2d21f7ce33074c6b26f3cff0af44b2a5159fc64fca3b0d`, closure SHA
`163ea2b3c4b9998d7f0519245c0447ba4df935b249326e4417f97264d0e53a36`, and diagnostic
binary SHA `4e68a6a54d5b9fec55c4507c4b5c3588b8cf8e10c3425615541cd91a3103e742`.
The private retry ledger and Mac raw receipt were independently reread through
their verifiers and the actual binary hash was checked. A post-build native walk
reported 710,189,669 ordinary bytes including bootstrap, 423,285,284 Cargo bytes,
and 167,939,777 bytes within the same target. The first attempt remains failed;
the build alone is not an 11-file extraction E2E or a performance result.

### 2026-10-27: one instrumented decode E2E

The separately reviewed noncomparative runner
`6b898fb249512dbe8b35d503c05b0fe6fce1766bb136009a71e6ac7e111a39ec`
validated the fixed archive, input manifest, source, build receipt/closure and
binary before and after execution. A single Mac invocation completed with
11 files and 2,810,784 bytes restored; the exact file set, lengths and SHA-256
matched the registered input manifest. The 27-phase report passed its schema,
counter, inclusive-duration and missing-measurement checks. The 24-capture
observer and owned helper/group closure passed. Native wall time including the
observation interval was 32.37269525s; charged usage was 2,964,986 bytes and
50 entries, including the journal reserve.

Terminal SHA `cc6a0f45af705522009bd727140f96e77af085a0aeb46f1a7b7e2247fc1bd78e`,
raw phase stdout SHA `bd5906b4a26bf241a150d06c037a08e9b037da61111fad916712226311aa1b96`,
closure SHA `a956794693bacdc73bd24fdc1eac609adfefa32deb90670a0b178b76314ddf73`.
The 37 raw proof members, including all 24 captures, terminal, raw stdout,
measurement, closure, report, restored manifest and runner, are retained in
`mac-khc-decode-phase-run-20261027-proof.zip` in the keep root (28,028 bytes,
SHA `a6b00c61247dc9ff8eff11889fcdd0c3cc1119397be886b3d922c2a9f36c7016`).
Their manifest, sizes and hashes were independently verified after transfer.

The measured inner extraction interval was 123.396ms: inclusive archive
decompression 64.184ms and file `sync_all` 47.007ms; within block decode the
MDL entropy loop was 30.074ms over eight calls and inverse processing 12.943ms.
These are nested inclusive phases from one instrumented diagnostic, not additive
totals, a 7-Zip comparison, or a speed-improvement measurement. The surrounding
spawn/wait measurement includes diagnostic monitoring and is not a benchmark.
The result directs investigation toward entropy decoding while preserving the
existing output and synchronization contract; no format or codec behavior was
changed on the strength of this measurement alone.

An independent read-only review recomputed the raw artifact hashes, closure,
all 24 observer records and all 11 actual restored file hashes before cleanup.
Maximum entry CPU was 9.4510%, runtime CPU 10.2992%; all captures reported
thermal state 0 and AC. After evidence preservation and verification, only the
11 diagnostic output copies were removed from this run's `decoded` directory:
their exact file set, contents, ownership and single-link type were checked first.
This reclaimed 2,810,784 logical bytes. The original reference archive, input
manifest, raw proof and completed terminal remain; terminal counts describe the
run before cleanup and are not rewritten.

The next bounded ablation investigates the existing MDL `Cdf::choose` small
linear scan using fixed-width comparisons, with the same CDF intervals, wire
format and safety checks. A separate component-constant token walk is another
unmeasured possibility, not combined with the first ablation. Neither is a new
compression principle; improvement is unproven. Prior KFT1/KHT1 flatten/rANS
variants were already measured and rejected for slower decoding and must not be
replayed as an allegedly new candidate. The separately identified derived source
must change only the intended decoder operation, preserve the measured baseline,
pass byte-identical restore and malformed-input checks, then undergo a fixed,
balanced paired comparison before any adoption or 7-Zip superiority claim.

The fixed pre-measurement plan is `cdf-chooser-evaluation-20261027.md`: one
warmup per binary, ten balanced pairs with five per order, fixed decode/noise,
encode and RSS gates, and invalid-run conditions. It was independently reviewed
before candidate execution. The source-only generator
`cdf-chooser-ablation/generate.py` SHA
`d53ac89d00407f830de4a4b0d437a85c1a75ec9cfe430c6084bbe6e9a8946810`
and its eight pure checks were independently reviewed. The saved candidate ZIP
in the keep root is `mac-cdf-chooser-ablation-source-36d904e0.zip`, 301,654 bytes,
SHA `36d904e04917022328d7aa41f0f2aeea03d1827348f11f7b261b392013b5fc05`,
manifest SHA `d711acf1989b34f5043d5a7bae68ea95c2d51a72f602ca6ca27124e5ebffc7e2`.
Exactly `src/khc/block/packet.rs` changes and 77 other records are byte-identical;
the original bytes are recovered by inverse replacement. The finite Python
witness and rustfmt check succeeded, but these are not a Rust compile, archive
E2E, malformed-input result or performance measurement. No candidate build or
timing has yet occurred.

For a later bounded Mac build, the candidate-specific single-walk capacity scanner
`mac-cdf-candidate-snapshot.py` is SHA
`80b14beefefbee2f4559f6c50a128794c7c5240ca8f08d606a4818ee4feb1f7f`.
Its only byte change from the reviewed diagnostic scanner `b99b…` is the fixed
candidate target path. It counts all existing Cargo targets as actual usage and
reserves only the unused portion of the candidate's 512 MiB allowance. The parent
reran 23 tests, including real Windows rename/hardlink I/O with UID/mode injected;
these are not Mac permission tests. The two temporary test roots were moved to the
recycle bin via Prunlet operation `26b3346ea95b46979b11d6e60b7e18db`. A separate
candidate build controller and Windows gateway were under development at that
checkpoint; no candidate source had yet been transferred, registered or built.

The candidate source, fixed controller/snapshot and canonical protocol were then
transferred to the approved Mac. Read-only preflight verified the 78-record source
pair, only the intended packet change, unchanged baseline and diagnostic binaries,
and the full candidate reservation inside the existing limits. The reviewed Windows
gateway was run once and retained the raw result in its separate private ledger.
The native build completed normally in 72.393060417s, including 68.250935625s of
supervised Cargo time; source/tool/old artifact postchecks and group closure passed.
The protocol SHA is
`8c6f4576d868e43158ade779ee176719bc6a7281d4420a4bfe3d371d25ab0082`,
terminal raw SHA
`34047b6793caa999e6dddc95a51b0b8c35e12218f1c9bf59e3834d89885cb23c`,
closure SHA `d180b552023a06f47672116be0a71f60950183fcc328415522c9c323523baeeb`,
candidate CLI SHA `cc36350705aff86fb4c8bf36e9d6f3d409c1fd4bf6b3d4fd6f1853e5add22632`,
and candidate `khc_spatial_mdl_e2e` example SHA
`0af3b9cc1823566c129c1bf989f4e53720bc8db843bb152c504d744bf556e59c`.
Windows ledger and Mac raw receipt/binary were independently reread. Post-build
accounting was 713,201,135 ordinary bytes including bootstrap, 602,512,307 Cargo
bytes including the 179,227,023-byte candidate target. The older diagnostic target
remains included in Cargo usage. Build success does not establish equivalent Rust
behavior, complete restoration, malformed-input rejection or speed improvement.

An independent read-only review revalidated the build terminal, raw closure,
actual CLI and example, both source trees and all preserved inputs. The baseline
and candidate `bin-unlhare-cli.json` release fingerprints have identical SHA;
each CLI also matches its own fingerprinted `deps/unlhare_cli-a9fec4c63883e867`.
The recorded rustc/features/target/profile/rustflags/config/compile-kind and build
selection match. `build.rs` bytes match but mtimes differ, and the historical
corrective clippy/build-script invocation history has not been proven equivalent;
retain this limitation for the comparison audit. Candidate behavior, native
malformed-input E2E, archive equality and speed remain unmeasured.

Candidate correctness E2E is being prepared as a separate, genuinely registered
storage run through `run-storage-experiment.ps1`; the previous E2E record and its
34 checks are not reused. The independently pinned candidate example above is not
a field of the build receipt and is checked as a separate artifact. The candidate
endpoint SHA is
`da6231a6f6fb61b04fd2c7833661a6a4467d3ee14db5d9fcf6e19ae2731b79ba`,
and canonical E2E protocol SHA is
`95b2fd0228cca0f440d4a45998d6d2ad709b0e6cf20a5e42db6a439eccf67d5c`.
Both were transferred to the Mac. A read-only preflight checked the fixed example,
candidate build chain, 78 source records, 513,216-byte fixture, 23 API archive
suffixes from the old oracle, and 8 MiB admission; the new RUN and start were absent.
Eight endpoint pure checks passed and its final code was independently reviewed.
Windows registration/gateway binding and final review remain in progress: no
candidate correctness RUN has been registered or executed yet.

After that checkpoint the reviewed gateway registered Windows RUN
`8fd4b003ba9e406da5a21b9be5a37c56`, but the 360-second Windows envelope was
exceeded. The runner exited 1 with a durable failed result and deadline veto;
the saved result reports child started, PID 0, unknown child exit and no cleanup
request. The owner process and matching Windows worker/SSH processes were absent
on subsequent inspection. Mac read-only checks found no matching endpoint
process, no `mac-cdf-candidate-e2e.started.json` or terminal, and no fixed Mac
E2E RUN directory. Thus the candidate example has **not been shown to run**, and
no correctness pass, 11-file equality, malformed-input result or performance
result is claimed. This does not by itself prove every intermediate process exit
or identify which repeated preparation operation consumed the time.

The private claim, reservation, registration, invocation, failed runner result
and deadline veto remain in their original run/ledger locations. The RUN remains
unresolved and the one-shot purpose is consumed; do not erase or bypass it with
a new GUID, target, altered deadline or silent retry. Investigate the prelaunch
overhead and the supported recovery/closure evidence before deciding how to
continue. Previous native build success and its proof are unchanged.
The fixed Mac RUN/start/terminal were absent after the Windows failure, but a
Windows child did start and an endpoint may have exited before writing start;
the absence does not prove that it was never invoked. The original root failure
was overwritten by the deadline error in `runner-result.json`, so its cause is
unknown. Raw run record SHA is
`799ef6ddb3f4c60b592ef1c6874fafe9f80c7574aab58ea87aaa59d5ee490f4e`,
invocation SHA `93b1b7140547e0adcfda3952a7da3c87809d02a8cce5260efd3b6e7a12e14b00`,
failed runner-result SHA `3038dca1472fce3e808c97de5ed7a65f52dd65a8b3b745160933bfb3509e4be6`,
deadline veto SHA `b719fcdc557756bba4c45efd556265c26b306da3697c20cc12a93c917530664a`,
claim SHA `12ff3b89c0ac6631e90daa10de6c0cf2a1bf62a426ec2609ac969e9a810b2436`,
and private registration SHA
`04d6ba78537416ae3bcddd51ed0d69bf5abb7b418109d8011da9e989b2d0df35`.

A single read-only instrumentation of `Get-KhcRecycleV6Charges` after the failure
completed in 24.1379563s. It charged payload 14,003,868 B, metadata 37,748,736 B,
total 51,752,604 B, and invoked the continuous proof verifier 43 times, diagnostic
verifier 16 times, retry verifier 6 times and candidate verifier 4 times within
that one scan. Inclusive function timings cannot be summed; this measurement does
not reconstruct the exact 373-second failed run or its lost initial exception.
Independent review identified repeated complete ledger verification per related
file as a likely contributor. The next local correction is scoped to deduplicating
verification within one scan while still validating all underlying bytes, entries,
accounting and pending states, preserving the first error with any later deadline
error, and refusing to start a child when the fixed envelope has insufficient time.

The local correction was implemented and independently reviewed. The parent reran
418 selected pure/old-evidence/gateway checks; the worker also ran 256 recycle-v6
and 41 continuous-lifecycle regressions. A post-change read-only scan took
13.9026835s and returned the same 51,752,604 B charge as the earlier scan. Within
that scan, 69 verifier calls reduced to nine unique complete wire verifications;
each record, identity, pending state and charge remained checked. This is one
before/after observation and does not prove that registration will fit 30 seconds.
The runner now preserves the initial and finalization/deadline errors together and
requires at least 330s remain before child spawn/gate. Fixed hashes are module
`8e0bab445470c0387db4b7f68dbd6c008a296061ff4fc0b3e96451291b6ec2a5`, runner
`21b2b5a9dbb3d650cc5810e42db91d14a8f3b7b9575e9c1efe3655a31f23c932` and test
`53170a899b0656c560a61e4f6a316591f45713203c21037d997e5a08551267e5`.
The old run remains unresolved. An independently reviewed recovery design requires
an actual fence against any remaining old worker/SSH, an authenticated observation
of the Mac fixed paths under that fence, and a separate not-started record plus an
explicit one-attempt amendment. No such fence/transition exists yet. Registration-
before-budget and worker SSH-immediately-before deadline binding remain to be
implemented in that new contract; this change alone does not authorize a retry.

Read-only design review identified a possible forward fence: an exclusive empty
directory at the old endpoint's fixed start-record pathname would conflict with
its `open(..., 'xb')` before it can reach the example. This is not yet installed
or an authorization to resume. In isolated Mac scratch directories, 20 concurrent
file-create versus mkdir races each had exactly one winner (directory won all 20),
and separate ordered checks confirmed file-first blocks mkdir and directory-first
blocks exclusive file creation. All scratch entries were removed. This validates
only the tested filesystem's pathname exclusion; it does not prove past absence,
Windows Job closure, resistance to unauthorized deletion, or that any dedicated
recovery transition is safe. The fixed start pathname and old RUN remain untouched.

Read-only native code inspection of the pinned baseline and candidate CLI used
Apple LLVM 21.0.0 `llvm-objdump` SHA
`792a7ab8593499fabb6316aa915de8833d61949d6329f89a0d6416f8ed99f4c8`
and the same `unlhare::khc::block::token` symbol. Both disassemblies contained
313 decoded instructions at the same positions; 298 opcode positions differed.
The ordered opcode-text SHA was
`c1c754c85792b7332a74c88e1d26bdfd9991b055635f5e71700854290cba7ca6`
for the baseline and
`ab8f8b7c6e8a52a3a722f82ad1426f5484926546789998925296804c4dfcc5ee`
for the candidate. This confirms that the compiled code differs in the targeted
function; it is not evidence of semantic equivalence or a speed improvement.

Before publishing a candidate E2E registration, the runner now checks the same
parent stopwatch and requires at least 330 seconds of the 360-second budget.
The check alone does not bound registration duration or bind the child SSH
admission to the parent stopwatch; therefore it does not authorize a retry.
Runner SHA256 `d82a75d167409e8a7e87d4b276ffe9fff1fc83a83ca906efc55d2ddf689d8c96`;
regression script SHA256 `2740b14b519b293876dbe5a1299830fdd9223b487aa7abc7afc5426cc3e433b3`.
The existing combined regression command passed 428 cases, including boundary
checks; independent review accepted the scoped guard.

A source-only proposed old-start fence and its test were prepared locally. The
nine pure tests passed after correcting the post-fence absence schema and nonblocking file opens; no fence was installed, no old pending record was
cleared, and no new E2E attempt was registered. Its evidence expressly leaves
past start, Windows Job closure, and third-party deletion unknown. Windows-side
binding, a dedicated recovery transition, live verification, and Darwin fsync
remain prerequisites for any use.

Read-only SSH observation: Mac `kern.boottime` was 2026-10-26 16:13:53 UTC;
old candidate run was recorded at 2026-10-26 21:35:33 UTC. At 22:16:23 UTC,
`ps` showed no command matching the fixed candidate endpoint or example name.
This is a point-in-time process-name observation, not proof of Windows Job
closure, historical non-start, or absence of differently named processes.

Independent read-only inspection found that the candidate correctness endpoint
runs only the ptt5 example/API. It does not run candidate CLI create/extract or
malformed-archive CLI cases. The existing baseline CLI E2E uses two files, not
the preregistered 11-file corpus. No implementation of the preregistered ten-pair
AB/BA comparison was located. Therefore a successful candidate example alone
would not meet the CLI parity or timing prerequisites. An executable protocol
must bind corpus bytes, CLI arguments and environment, malformed fixtures,
per-child timing/RSS, ordering, invalidation, and transient output accounting
before any comparison; the preregistered acceptance thresholds remain unchanged.

Candidate registration now scopes immutable pure-verifier memo and read leases
to its single `New-KhcStorageRun` operation. Each charge scan still rereads
metadata and recomputes accounting, pending and claim checks. Candidate E2E
stdin wire SHA, run/record identity, arguments and dependency pins bind its
cache key; leases and results do not cross operation boundaries. The combined
pure regression suite passed 431 cases and independent static review passed.
Module SHA `650a577eb81f98543de295be8bebf655f2060a70d91c943677f4c4b171f8e113`;
test SHA `063d4f91b479cac6d220980848754c984e261cfe28b504c560460ba5bbdcca57`.
This does not demonstrate a 30-second registration, bind the SSH admission
deadline, resolve the old pending run, or authorize a new experiment.

A fixed old-attempt read-only evidence reader was added under
`candidate-e2e-recovery/`. The parent independently ran 10 pure tests and the
reader against the eight retained files: all pinned hashes matched and the result
remained `failed-pending-closure-unknown`, with start/cleanup disallowed. Its
handle-close failure behavior was corrected after independent review. It does not
prove past process closure or permit a new run.

`cdf-cli-evaluation/` now contains an adapter-driven development-corpus CLI
campaign model: fixed corpus and CLI vectors, two preflights, two warmups, 10
AB/BA pairs, output equality and preregistered statistics. Parent reran 11 pure
tests; independent static review passed after correcting observation snapshots,
error classification and bounded archive reads. Native execution remains closed:
real process supervisor, malformed-input/chooser evidence, observation, lifecycle
registration, deadline, storage and cleanup integration are not implemented.
No measurement or candidate adoption follows from these test-adapter results.

Read-only malformed-fixture analysis found that archive extraction publishes
entries individually before the final archive footer is checked. Thus a valid
one-file payload may already exist when a truncated footer or trailing bytes are
rejected; testing must not assume archive-wide atomic extraction. A fresh output
root and per-fixture expected publication state are required. Invalid wire CDF
rows are validated before `Cdf::choose`, so a malformed CDF case does not prove
the chooser boundary behavior. A block-body bit flip without resealing its CRC
only establishes the wire-CRC rejection path. A correctly framed/resealed invalid
CDF fixture and the separate chooser witness remain to be built and verified;
no malformed CLI run was performed here.

The candidate development campaign now has a source-only supervisor/observer
adapter with frozen validator calls and a Darwin wait4 helper primitive. It
checks 48 child observations and preserves closure bindings and multiple errors.
The parent ran 14 adapter and 12 evaluation pure tests; independent static
review passed after corrections. These use mock processes or synthetic proofs,
not a Mac process. Native factory remains closed: authenticated helper deployment,
48-event capture budget, total deadline, lifecycle and durable failure evidence
are still unconnected.

A malformed-input byte generator now produces extent, truncated footer, header
CRC corruption, and unknown-revision variants from a verified input; it does no
filesystem writes. Four pure tests and an independent static review passed. It
checks outer byte spans, not complete revision-specific input validity. A validly
framed invalid-CDF fixture, safe persistence and actual CLI rejection remain
unverified. The old-attempt binding/transition draft also passed six pure tests
and review; its live bridge and permission path remain closed and old pending
is retained.

A fixed helper request encoder/validator and bridge command construction were
added for the proposed Darwin wait4 path. The parent reran helper 5, adapter 16,
and evaluation 12 tests; independent review passed after binding received pins
before source compilation. A separate local Python subprocess exercised request
validation and refusal, not a Darwin wait4 child. The real `--run` and campaign
entry remain closed pending authenticated lifecycle capability, fixed helper
installation, live old-fence proof, resource reservation and native verification.

Malformed fixture export now accepts only bounded immutable input with a pinned
SHA and writes to caller-provided streams, then performs bounded readback and SHA
checks. The parent reran 10 tests; no filesystem path, durable receipt or actual
CLI use was validated. A dedicated recovery review confirmed that the old fixed
endpoint cannot be reused after fencing its start path; a new prefix, live bridge,
locks, old reservation accounting and a one-attempt amendment are still required.
Old pending and claim remain unchanged.

A recovery-specific endpoint and fixed protocol were created in
`candidate-e2e-recovery/`, with distinct RUN and journal names. Parent reran ten
pure endpoint tests. Independent review required and confirmed content-only
receipt summaries: they do not authorize recovery or cleanup. Native entry still
refuses before side effects; live fence, lock, claim, registration, and receipt
proof integration remain absent.

The proposed 48-event observer protocol uses 240 captures at 1.25-second
intervals within existing native/Windows deadlines. Parent reran six protocol,
18 adapter and 12 evaluation pure tests. Independent review found and confirmed
a correction binding closure monotonic times to their observation event. This
is not a native measurement: observer overhead, absolute lifecycle deadline
and 350-second completion remain unverified and native execution is disabled.

A recovery worker with separate fixed names and pre-side-effect denial was added;
parent reran 12 pure contract tests and independent static review passed. The
required recovery lifecycle functions, live fence, claim and receipt/seal proof
remain unimplemented, so it cannot yet launch a real worker.

The observer adapter now derives the 317-second observer and 330-second abort
boundaries from native monotonic start. Parent reran 25 adapter and six observer
pure tests; independent review passed after fixing deadline rechecks and common
abort handling. The real authenticated native clock, abort implementation,
child start budget and parent Windows deadline remain unconnected. No Mac
candidate or comparison ran.

Candidate evaluation child admission now clamps the outer supervisor timeout
against the native observation deadline and rechecks just before spawn. A race
review led to a dedicated supervisor and bridge-wide nonblocking lock; parent
reran 32 pure adapter tests and independent static review passed. The real
native clock/lifecycle/cleanup guarantees remain unconnected and Mac execution
is disabled. Separate recovery registration analysis confirmed that new
amendment/claim metadata requires coordinated schema, charging and proof handling;
no old pending, claim, or capacity accounting was changed.

Reassessment: the 48-event observer and wait4 evaluation tooling is not a
prerequisite for the separate candidate example correctness run. Existing
pending, stopped-run and aggregate-capacity rules still apply. The narrow next
step is a single recovery amendment tied to the old failed run and a live fence,
then the existing finite candidate example E2E; historical Windows Job closure
and historical non-start remain unknown, not newly required claims. Full CLI
correctness and performance comparisons remain separate subsequent gates.

The apparent double wire-CRC scan was checked against the retained diagnostic
proof ZIP (SHA a6b00c61247dc9ff8eff11889fcdd0c3cc1119397be886b3d922c2a9f36c7016).
The decode header/wire phase measured 7,958 ns in ten calls out of 123,395,625 ns
outer elapsed in this one instrumented sample. This is an upper bound for that
sample's potential inner-CRC saving, not a general benchmark. No CRC change is
justified by this observation; existing correctness checks remain in place.

Scope reassessment: the 48-event comparison machinery is not required before the
single 8MiB candidate example correctness recovery. Old pending/claim/reserve
and the fixed capacity remain mandatory. A source-only one-shot marker and fence
operation was added in `candidate-e2e-recovery/fence_bridge.py`; parent reran
four pure tests and independent static review found no additional defect in its
limited operation. It has no native entry or authorization; Windows evidence and
lock, resource accounting, bounded SSH/closure, and receipt recovery are still
unconnected. No Mac operation or real fence creation was performed.

The source-only fence launcher was reviewed and three findings reproduced and
fixed: check the absolute deadline after admission and immediately before spawn;
retain failure or deadline evidence without treating observations as eligible;
and release the lock if acquisition's anchor context fails. Parent ran 20 pure
checks and independent static review passed. Fixed child entry, authenticated
Windows bridge, capacity accounting and external seal remain unconnected; no
Mac execution or fence creation occurred.

Fixed launcher source now includes the planned child-FD handoff and pinned
same-handle dependency loading. Independent review found that this did not
establish Windows lifecycle authorization and that acquiring flock is not proof
of an authenticated parent. Both native CLI paths were changed to refuse before
side effects; parent reran 17 pure launcher tests and independent review
confirmed the refusal. The actual lifecycle binding, SSH, resource accounting
and Mac FD behavior remain unverified; no remote operation was performed.

At user-requested pause, recovery-specific kind, data schema, cross-binding,
pending-set and content-only receipt validators were added to storage-lifecycle.
They are not connected to live registration, pending enumeration, a pinned raw
receipt verifier, live fence, closure or external seal. Parent ran 145 pure
assertions; worker ran existing recycle 256 and worker 12 cases. Independent
static review found JSON Int64 handling, string-type checks and done receipt
SHA issues; all were corrected and independently rechecked. Module SHA
`fb3b60dfceefee3f86b4d11dea356e0410515d1105ec6b8e293720539eb7a323`;
test SHA `da0150a8e1ac57d5a15208987840ca9bcb4f1c479f2d1558862f98b06933e70b`.
Old pending/claim/reserve remain unchanged. No Mac/SSH/real registration took
place. Resume at real lifecycle integration with live proof and finite SSH;
candidate CLI correctness and 7-Zip comparison remain unperformed.
