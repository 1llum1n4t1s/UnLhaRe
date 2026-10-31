# 実装前の失敗条件（実Windows E2E。製品stateを書き換えない）:
# 1. 不在を0にできない、ファイル総量が不正、祖先/子孫reparseを追跡する。
# 2. 固定容量の予約超過を許す、既存/相対/wildcard/外部のworkを所有する。
# 3. 別processがactive lock中にrunを開始し、拒否後にworkが残る。
# 4. 所有run以外を消す、ZIP/SHA復元が一致しない、三者不在の台帳が欠ける。
# 5. 連続する2runでsourceが残る、完了後もlockが残る、検証fixtureが残る。
# 6. 実wrapperの成功/非0/timeout/background子で終了を確認せず清掃する。
# 7. 受付した最大bytesと最大entriesを同時に使うと清掃予約が失敗する。
# 未完了runは正規APIで作り、lock解放後の次run拒否→正規完了で回復する。
# helper失敗時は別削除経路を使わず、復元証拠と残存pathを保持して失敗する。
[CmdletBinding()]
param([ValidateSet('none','success','nonzero','timeout','background')][string]$FixtureMode='none',[string]$WorkDirectory)

throw '旧E2Eは直接削除を含むため無効化しました。Prunletの二段階検証にはtest-storage-staged-e2e.ps1を使ってください。'

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'このE2Eは実Windowsのストレージ管理を検証します。'
}
$modulePath = Join-Path $PSScriptRoot 'storage-lifecycle.psm1'
Import-Module $modulePath -Force -ErrorAction Stop
if ($FixtureMode -ne 'none') {
    Assert-KhcStorageContext -WorkDirectory $WorkDirectory
    $null=New-Item -ItemType Directory -Path $WorkDirectory
    [IO.File]::WriteAllBytes((Join-Path $WorkDirectory 'fixture.bin'),[byte[]](0,1,2,255))
    if ($FixtureMode -eq 'nonzero') { throw 'E2E expected child failure' }
    if ($FixtureMode -eq 'timeout') { [Threading.Thread]::Sleep(60000) }
    if ($FixtureMode -eq 'background') {
        $info=[Diagnostics.ProcessStartInfo]::new((Get-Command pwsh -CommandType Application | Select-Object -First 1).Source)
        $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
        $info.ArgumentList.Add('-NoProfile');$info.ArgumentList.Add('-Command');$info.ArgumentList.Add('[Threading.Thread]::Sleep(60000)')
        $child=[Diagnostics.Process]::Start($info)
        [IO.File]::WriteAllText((Join-Path $WorkDirectory 'background-pid.txt'),[string]$child.Id)
        $child.Dispose()
    }
    return
}

$id = 'storage-e2e-' + [Guid]::NewGuid().ToString('N')
$tempBase = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) 'Codex/UnLhaRe'))
$fixture = Join-Path $tempBase $id
$proof = [IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) "Codex/TaskArtifacts/UnLhaRe/$id"))
$checks = [Collections.Generic.List[object]]::new()
$active = $null
$completionAttempted = $false
$link = Join-Path $fixture 'junction'
$failure = $null

function Assert-E2e([bool]$Condition, [string]$Name) {
    if (-not $Condition) { throw "E2E失敗: $Name" }
    $checks.Add([pscustomobject]@{ name = $Name; passed = $true })
}

function Assert-Refusal([scriptblock]$Operation, [string]$Name) {
    $refused = $false
    $unexpected = $null
    try { $unexpected = & $Operation } catch { $refused = $true }
    # 拒否対象を誤って所有した場合でも削除せず、lockだけ解放する。
    if ($unexpected -and $unexpected.PSObject.Properties['Lock']) { $unexpected.Lock.Dispose() }
    Assert-E2e $refused $Name
}

function Assert-CompleteLedger([string]$Path) {
    $ledger = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    Assert-E2e ($ledger.state -eq 'complete') "台帳complete: $Path"
    Assert-E2e (@($ledger.items).Count -gt 0) "台帳に処理対象: $Path"
    foreach ($item in $ledger.items) {
        Assert-E2e ($item.sourceAbsent) "元パスが不在: $Path"
    }
}

function Remove-OwnedFixture([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    # 復元用コピーも、その現在内容のZIPを保持してから清掃する。
    $backup = Join-Path $proof ('fixture-' + [Guid]::NewGuid().ToString('N') + '.zip')
    [IO.Compression.ZipFile]::CreateFromDirectory($Path, $backup)
    $receipt = & {
    param([string[]]$Paths, [string]$Root, [string]$Ledger, [switch]$ReturnReceipt, [switch]$AllowLeafLink, [switch]$IgnoreMissing)
    if ([string]::IsNullOrWhiteSpace($Root) -or -not [IO.Path]::IsPathFullyQualified($Root)) { throw 'Absolute cleanup root required' }
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd('\','/')
    if ($rootPath -eq [IO.Path]::GetPathRoot($Root).TrimEnd('\','/')) { throw 'Filesystem root cleanup prohibited' }
    if ($Paths.Count -eq 0) { throw 'Empty cleanup target set' }
    $rootItem = Get-Item -LiteralPath $rootPath -Force -ErrorAction Stop
    if (-not $rootItem.PSIsContainer) { throw 'Cleanup root must be a directory' }
    $validated = [Collections.Generic.List[string]]::new()
    $owned = @(foreach ($path in $Paths) {
        if ([string]::IsNullOrWhiteSpace($path) -or -not [IO.Path]::IsPathFullyQualified($path)) { throw 'Absolute cleanup target required' }
        $full = [IO.Path]::GetFullPath($path).TrimEnd('\','/')
        if (-not $full.StartsWith($rootPath + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw "Cleanup target outside root: $full" }
        foreach ($prior in $validated) {
            if ($full -eq $prior -or $full.StartsWith($prior + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or $prior.StartsWith($full + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Duplicate or overlapping cleanup targets' }
        }
        $validated.Add($full)
        if (-not (Test-Path -LiteralPath $full) -and -not $IgnoreMissing) { throw "Cleanup target missing: $full" }
        for ($cursor = $full; $cursor; $cursor = [IO.Path]::GetDirectoryName($cursor)) {
            if (Test-Path -LiteralPath $cursor) {
                $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -and -not ($AllowLeafLink -and $cursor -eq $full)) { throw "Cleanup link refused: $cursor" }
            }
        }
        if (Test-Path -LiteralPath $full) {
            $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
            if ($item.PSIsContainer -and -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                $pending = [Collections.Generic.Stack[string]]::new(); $pending.Push($full)
                while ($pending.Count) {
                    foreach ($child in Get-ChildItem -LiteralPath $pending.Pop() -Force -ErrorAction Stop) {
                        if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Cleanup child link refused: $($child.FullName)" }
                        if ($child.PSIsContainer) { $pending.Push($child.FullName) }
                    }
                }
            }
        }
        $full
    })
    if ($Ledger -and @( $owned | Where-Object { $Ledger -eq $_ -or $Ledger.StartsWith($_ + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) }).Count) { throw 'Cleanup ledger is inside target' }
    $entries = @(foreach ($full in $owned) {
        if (Test-Path -LiteralPath $full) {
            $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { Remove-Item -LiteralPath $full -Force -ErrorAction Stop }
            else { Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop }
        }
        if (Test-Path -LiteralPath $full) { throw "Cleanup target remains: $full" }
        [pscustomobject]@{ original = @{Path=$full}; sourceAbsent=$true }
    })
    if ($Ledger) {
        New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($Ledger)) -Force | Out-Null
        [pscustomobject]@{state='complete'; items=$entries; protocol='direct-delete'} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Ledger -Encoding utf8
    }
    if ($ReturnReceipt) { foreach ($full in $owned) { [pscustomobject]@{Target=$full; State='complete'; LedgerPath=$Ledger} } }
} -Paths $Path -Root $tempBase -Ledger (Join-Path (Join-Path $proof 'cleanup') ([guid]::NewGuid().ToString('N') + '.json')) -ReturnReceipt
    Assert-CompleteLedger $receipt.LedgerPath
    Assert-E2e (-not (Test-Path -LiteralPath $Path)) "fixture不在: $Path"
}

try {
    # 保存先はproduction読取APIで祖先も検査し、予約を通してから作成する。
    Assert-E2e ((Get-KhcTreeUsage -LiteralPath $fixture) -eq 0) '不在treeは0bytes'
    Assert-E2e ((Get-KhcTreeUsage -LiteralPath $proof) -eq 0) '証拠保存先は新規・非reparse'
    $snapshot = Assert-KhcStorageBudget -ReserveBytes (1MB)
    Assert-E2e ($null -ne $snapshot) '固定aggregate容量snapshotを返す'
    Assert-Refusal { Assert-KhcStorageBudget -ReserveBytes (4GB) } '既存量込みのaggregate上限を超える予約を拒否'
    $null = New-Item -ItemType Directory -Path $fixture
    $null = New-Item -ItemType Directory -Path $proof
    [IO.File]::WriteAllBytes((Join-Path $fixture 'sentinel.bin'), [byte[]](0, 1, 2, 255))
    $sentinelHash = (Get-FileHash -LiteralPath (Join-Path $fixture 'sentinel.bin') -Algorithm SHA256).Hash
    $null = New-Item -ItemType Directory -Path (Join-Path $fixture 'ordinary')
    [IO.File]::WriteAllBytes((Join-Path $fixture 'ordinary/nested.bin'), [byte[]](7, 8, 9))
    $targetHash = (Get-FileHash -LiteralPath (Join-Path $fixture 'ordinary/nested.bin') -Algorithm SHA256).Hash
    Assert-E2e ((Get-KhcTreeUsage -LiteralPath $fixture) -eq 7) 'nested treeを正確に集計'

    Assert-Refusal { New-KhcStorageRun -WorkDirectory $fixture -MaxRunMiB 1 } '既存workを所有しない'
    Assert-Refusal { New-KhcStorageRun -WorkDirectory './relative-storage-e2e' -MaxRunMiB 1 } '相対pathを拒否'
    Assert-Refusal { New-KhcStorageRun -WorkDirectory (Join-Path $fixture 'wild*') -MaxRunMiB 1 } 'wildcardを拒否'
    Assert-Refusal { New-KhcStorageRun -WorkDirectory $proof -MaxRunMiB 1 } 'Temp許可root外を拒否'
    Assert-Refusal { New-KhcStorageRun -WorkDirectory $PSScriptRoot -MaxRunMiB 1 } 'repositoryを拒否'
    Assert-Refusal { New-KhcStorageRun -WorkDirectory 'C:/Users/IMT/.codex' -MaxRunMiB 1 } 'Codex設定rootを拒否'

    $null = New-Item -ItemType Junction -Path $link -Target (Join-Path $fixture 'ordinary')
    Assert-Refusal { Get-KhcTreeUsage -LiteralPath $fixture } '子孫reparseを拒否'
    Assert-Refusal { Get-KhcTreeUsage -LiteralPath (Join-Path $link 'missing') } '不在pathの祖先reparseを拒否'
    Assert-Refusal { New-KhcStorageRun -WorkDirectory (Join-Path $link 'run') -MaxRunMiB 1 } 'reparse配下を所有しない'
    # link自身のdescriptorを保存し、対応済みの限定junction経路だけ使用する。
    Get-Item -LiteralPath $link | Select-Object FullName, LinkType, Target, Attributes |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $proof 'junction-before.json') -Encoding utf8
    $linkReceipt = & {
    param([string[]]$Paths, [string]$Root, [string]$Ledger, [switch]$ReturnReceipt, [switch]$AllowLeafLink, [switch]$IgnoreMissing)
    if ([string]::IsNullOrWhiteSpace($Root) -or -not [IO.Path]::IsPathFullyQualified($Root)) { throw 'Absolute cleanup root required' }
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd('\','/')
    if ($rootPath -eq [IO.Path]::GetPathRoot($Root).TrimEnd('\','/')) { throw 'Filesystem root cleanup prohibited' }
    if ($Paths.Count -eq 0) { throw 'Empty cleanup target set' }
    $rootItem = Get-Item -LiteralPath $rootPath -Force -ErrorAction Stop
    if (-not $rootItem.PSIsContainer) { throw 'Cleanup root must be a directory' }
    $validated = [Collections.Generic.List[string]]::new()
    $owned = @(foreach ($path in $Paths) {
        if ([string]::IsNullOrWhiteSpace($path) -or -not [IO.Path]::IsPathFullyQualified($path)) { throw 'Absolute cleanup target required' }
        $full = [IO.Path]::GetFullPath($path).TrimEnd('\','/')
        if (-not $full.StartsWith($rootPath + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw "Cleanup target outside root: $full" }
        foreach ($prior in $validated) {
            if ($full -eq $prior -or $full.StartsWith($prior + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or $prior.StartsWith($full + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Duplicate or overlapping cleanup targets' }
        }
        $validated.Add($full)
        if (-not (Test-Path -LiteralPath $full) -and -not $IgnoreMissing) { throw "Cleanup target missing: $full" }
        for ($cursor = $full; $cursor; $cursor = [IO.Path]::GetDirectoryName($cursor)) {
            if (Test-Path -LiteralPath $cursor) {
                $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -and -not ($AllowLeafLink -and $cursor -eq $full)) { throw "Cleanup link refused: $cursor" }
            }
        }
        if (Test-Path -LiteralPath $full) {
            $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
            if ($item.PSIsContainer -and -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                $pending = [Collections.Generic.Stack[string]]::new(); $pending.Push($full)
                while ($pending.Count) {
                    foreach ($child in Get-ChildItem -LiteralPath $pending.Pop() -Force -ErrorAction Stop) {
                        if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Cleanup child link refused: $($child.FullName)" }
                        if ($child.PSIsContainer) { $pending.Push($child.FullName) }
                    }
                }
            }
        }
        $full
    })
    if ($Ledger -and @( $owned | Where-Object { $Ledger -eq $_ -or $Ledger.StartsWith($_ + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) }).Count) { throw 'Cleanup ledger is inside target' }
    $entries = @(foreach ($full in $owned) {
        if (Test-Path -LiteralPath $full) {
            $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { Remove-Item -LiteralPath $full -Force -ErrorAction Stop }
            else { Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop }
        }
        if (Test-Path -LiteralPath $full) { throw "Cleanup target remains: $full" }
        [pscustomobject]@{ original = @{Path=$full}; sourceAbsent=$true }
    })
    if ($Ledger) {
        New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($Ledger)) -Force | Out-Null
        [pscustomobject]@{state='complete'; items=$entries; protocol='direct-delete'} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Ledger -Encoding utf8
    }
    if ($ReturnReceipt) { foreach ($full in $owned) { [pscustomobject]@{Target=$full; State='complete'; LedgerPath=$Ledger} } }
} -Paths $link -Root $fixture -Ledger (Join-Path (Join-Path $proof 'cleanup') ([guid]::NewGuid().ToString('N') + '.json')) -ReturnReceipt -AllowLeafLink
    Assert-CompleteLedger $linkReceipt.LedgerPath
    Assert-E2e (-not (Test-Path -LiteralPath $link)) 'junction自身が不在'
    Assert-E2e ((Get-KhcTreeUsage -LiteralPath (Join-Path $fixture 'ordinary')) -eq 3) 'junction targetを保持'
    Assert-E2e ((Get-FileHash -LiteralPath (Join-Path $fixture 'ordinary/nested.bin') -Algorithm SHA256).Hash -eq $targetHash) 'junction targetのSHA保持'

    # 強制終了相当: lockがなくなっても未完了台帳の存在で次を止める。
    $pendingWork = Join-Path $fixture 'incomplete-run'
    $active = New-KhcStorageRun -WorkDirectory $pendingWork -MaxRunMiB 1
    $completionAttempted = $false
    $active.Lock.Dispose()
    Assert-Refusal { New-KhcStorageRun -WorkDirectory (Join-Path $fixture 'after-incomplete') -MaxRunMiB 1 } '未完了runが次の開始を拒否'
    Assert-E2e (-not (Test-Path -LiteralPath (Join-Path $fixture 'after-incomplete'))) '未完了拒否で次workを作らない'
    $completionAttempted = $true
    $null = Complete-KhcStorageRun -Context $active
    $active = $null

    for ($number = 1; $number -le 2; $number++) {
        $work = Join-Path $fixture "run-$number"
        $active = New-KhcStorageRun -WorkDirectory $work -MaxRunMiB 1
        $completionAttempted = $false
        Assert-E2e (-not (Test-Path -LiteralPath $work)) '開始受付はworkを作成しない'
        $null = New-Item -ItemType Directory -Path $work
        $null = New-Item -ItemType Directory -Path (Join-Path $work 'nested')
        [IO.File]::WriteAllBytes((Join-Path $work 'payload.bin'), [byte[]](0, 255, 128, $number))
        [IO.File]::WriteAllText((Join-Path $work 'nested/日本語.txt'), "run=$number`n")
        $expected = @(Get-ChildItem -LiteralPath $work -File -Recurse | ForEach-Object {
            [pscustomobject]@{ path = [IO.Path]::GetRelativePath($work, $_.FullName); bytes = $_.Length; sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
        })
        if ($number -eq 1) {
            # 独立processのproduction APIがactive lockを拒否することを検証する。
            $contender = Join-Path $fixture 'contender'
            $quotedModule = $modulePath.Replace("'", "''")
            $quotedContender = $contender.Replace("'", "''")
            $command = "`$ErrorActionPreference = 'Stop'; Import-Module '$quotedModule'; try { `$c = New-KhcStorageRun -WorkDirectory '$quotedContender' -MaxRunMiB 1 } catch { exit 23 }; `$c.Lock.Dispose(); exit 24"
            $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
            $start = [Diagnostics.ProcessStartInfo]::new((Get-Command pwsh -CommandType Application | Select-Object -First 1).Source)
            $start.UseShellExecute = $false
            $start.CreateNoWindow = $true
            $start.ArgumentList.Add('-NoProfile')
            $start.ArgumentList.Add('-EncodedCommand')
            $start.ArgumentList.Add($encoded)
            $child = [Diagnostics.Process]::Start($start)
            try {
                if (-not $child.WaitForExit(15000)) {
                    $child.Kill()
                    throw '別processのlock検証が15秒で終了しませんでした。'
                }
                Assert-E2e ($child.ExitCode -eq 23) '別processの同時開始を拒否'
            } finally { $child.Dispose() }
            Assert-E2e (-not (Test-Path -LiteralPath $contender)) '拒否されたworkは不在'
        }
        $completionAttempted = $true
        $completed = Complete-KhcStorageRun -Context $active
        $active = $null
        Assert-E2e ($completed.State -eq 'complete' -and $completed.AfterBytes -eq 0) 'run完了証拠を返す'
        Assert-E2e (-not (Test-Path -LiteralPath $work)) 'run source不在'
        Assert-CompleteLedger $completed.LedgerPath
        $manifest = Get-Content -LiteralPath $completed.ManifestPath -Raw | ConvertFrom-Json
        Assert-E2e ((Get-FileHash -LiteralPath $completed.BackupPath -Algorithm SHA256).Hash -eq $manifest.backup_sha256) 'ZIPのSHA一致'
        Assert-E2e (@($manifest.files).Count -eq $expected.Count) 'manifestのfile集合が完全'
        $restore = Join-Path $fixture "restore-$number"
        [IO.Compression.ZipFile]::ExtractToDirectory($completed.BackupPath, $restore)
        Assert-E2e (@(Get-ChildItem -LiteralPath $restore -File -Recurse).Count -eq $expected.Count) '復元file集合が完全'
        foreach ($file in $expected) {
            $restored = Join-Path $restore $file.path
            $entry = @($manifest.files | Where-Object { $_.path.Replace('/', '\') -eq $file.path.Replace('/', '\') })
            Assert-E2e ($entry.Count -eq 1) "manifest path一致: $($file.path)"
            Assert-E2e ($entry[0].bytes -eq $file.bytes -and $entry[0].sha256 -eq $file.sha256) "manifest bytes/SHA一致: $($file.path)"
            Assert-E2e ((Get-Item -LiteralPath $restored).Length -eq $file.bytes -and (Get-FileHash -LiteralPath $restored -Algorithm SHA256).Hash -eq $file.sha256) "ZIP復元bytes/SHA一致: $($file.path)"
        }
        Remove-OwnedFixture $restore
        Assert-E2e ((Get-FileHash -LiteralPath (Join-Path $fixture 'sentinel.bin') -Algorithm SHA256).Hash -eq $sentinelHash) '所有run外のsentinel保持'
    }
    # reviewerの容量境界: 上限ちょうどのbytes/entriesでも登録後の清掃予約が成立する。
    $work=Join-Path $fixture 'maximum-accepted-entries'
    $active=New-KhcStorageRun -WorkDirectory $work -MaxRunMiB 1
    $completionAttempted=$false
    $acceptedEntries=$active.MaxEntries
    $null=New-Item -ItemType Directory -Path $work
    [IO.File]::WriteAllBytes((Join-Path $work 'full-budget.bin'),[byte[]]::new(1MB))
    for($index=1;$index -lt $acceptedEntries;$index++){$null=[IO.Directory]::CreateDirectory((Join-Path $work "empty-$index"))}
    Assert-E2e ((Get-KhcRunUsage -LiteralPath $work -MaxEntries $acceptedEntries) -eq 1MB) '受付した最大bytesと最大entriesを同時に許可'
    Assert-Refusal {Get-KhcRunUsage -LiteralPath $work -MaxEntries ($acceptedEntries-1)} '同じentry監視上限を超えたら拒否'
    $completionAttempted=$true
    $completed=Complete-KhcStorageRun -Context $active
    $active=$null
    Assert-E2e ($completed.State -eq 'complete' -and $completed.BeforeBytes -eq 1MB -and -not(Test-Path -LiteralPath $work)) '最大受付境界でも清掃が完了'
    Assert-CompleteLedger $completed.LedgerPath
    $zip=[IO.Compression.ZipFile]::OpenRead($completed.BackupPath)
    try{Assert-E2e ($zip.Entries.Count -eq $acceptedEntries) '空directoryも復元ZIPへ完全保全'}finally{$zip.Dispose()}

    foreach ($mode in @('success','nonzero','timeout','background')) {
        $wrapper=(Join-Path $PSScriptRoot 'run-storage-experiment.ps1').Replace("'","''")
        $testFile=$PSCommandPath.Replace("'","''")
        $timeout=if($mode -eq 'timeout'){1}else{10}
        $command="[Console]::OutputEncoding=[Text.UTF8Encoding]::new(`$false);`$ErrorActionPreference='Stop';try{ & '$wrapper' -ScriptPath '$testFile' -ScriptParameters @{FixtureMode='$mode'} -MaxRunMiB 1 -TimeoutSeconds $timeout }catch{Write-Output ('E2E wrapper failure: '+`$_.Exception.Message);exit 27}"
        $start=[Diagnostics.ProcessStartInfo]::new((Get-Command pwsh -CommandType Application | Select-Object -First 1).Source)
        $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
        $start.StandardOutputEncoding=[Text.UTF8Encoding]::new($false);$start.StandardErrorEncoding=[Text.UTF8Encoding]::new($false)
        $start.ArgumentList.Add('-NoProfile');$start.ArgumentList.Add('-EncodedCommand');$start.ArgumentList.Add([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command)))
        $child=[Diagnostics.Process]::Start($start)
        try {
            $stdout=$child.StandardOutput.ReadToEndAsync();$stderr=$child.StandardError.ReadToEndAsync()
            if(-not $child.WaitForExit(45000)){$child.Kill($true);throw "wrapper E2E deadline: $mode"}
            $output=$stdout.GetAwaiter().GetResult();$errors=$stderr.GetAwaiter().GetResult()
            Assert-E2e ($child.ExitCode -eq $(if($mode -eq 'success'){0}else{27})) "wrapper終了コード: $mode ($errors $output)"
            $json=@($output -split '\r?\n' | Where-Object { $_.StartsWith('{') })
            Assert-E2e ($json.Count -eq 1) "wrapper完了証拠: $mode ($output)"
            $completed=$json[0] | ConvertFrom-Json
            Assert-E2e ($completed.State -eq 'complete' -and -not(Test-Path -LiteralPath $completed.WorkDirectory)) "wrapper一時物不在: $mode"
            Assert-CompleteLedger $completed.LedgerPath
            if($mode -eq 'background'){
                $zip=[IO.Compression.ZipFile]::OpenRead($completed.BackupPath)
                try{$reader=[IO.StreamReader]::new($zip.GetEntry('background-pid.txt').Open());try{$backgroundPid=[int]$reader.ReadToEnd()}finally{$reader.Dispose()}}finally{$zip.Dispose()}
                Assert-E2e ($null -eq (Get-Process -Id $backgroundPid -ErrorAction SilentlyContinue)) 'root終了後のbackground子もJob終了'
            }
        } finally {$child.Dispose()}
    }
} catch {
    $failure = $_
} finally {
    if ($null -ne $active -and -not $completionAttempted) {
        try { $null = Complete-KhcStorageRun -Context $active } catch { if ($null -eq $failure) { $failure = $_ } }
    }
    # reparseが残った場合はtreeを再帰清掃せず保持する。失敗したhelperを再試行しない。
    if ($null -eq $failure -and (Test-Path -LiteralPath $fixture)) {
        try { Remove-OwnedFixture $fixture } catch { $failure = $_ }
    }
    if (Test-Path -LiteralPath $proof) {
        [pscustomobject]@{
            schema = 1; passed = ($null -eq $failure); checks = @($checks.ToArray())
            fixture = $fixture; fixture_absent = (-not (Test-Path -LiteralPath $fixture))
            failure = if ($failure) { $failure.Exception.Message } else { $null }
            unverified = @('helper failure latch', 'actual 30GiB/6GiB/2GiB/64MiB boundary saturation')
            retention = '小容量の復元ZIP・SHA・削除台帳を再現証拠として保持。調査完了後に所有範囲を確認して清掃。'
        } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $proof 'result.json') -Encoding utf8
    }
}
if ($failure) { throw $failure }
Write-Output "Storage lifecycle E2E成功: $($checks.Count) checks; 証拠: $proof/result.json"
