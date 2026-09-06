[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Workspace,
    [ValidateSet('legacy','A','W')][string[]]$Apis = @('legacy','A','W'),
    [ValidateSet('a32','w32','a64','w64')][string[]]$Layouts = @('a32','w32','a64','w64'),
    [switch]$RequireCaseSensitive
)
$ErrorActionPreference = 'Stop'
$TestProgram = (Resolve-Path -LiteralPath $TestProgram).Path
$Candidate = (Resolve-Path -LiteralPath $Candidate).Path
$runner = (Resolve-Path -LiteralPath (Join-Path (Split-Path -Parent $TestProgram) 'DesktopRunner.exe')).Path
$Workspace = [IO.Path]::GetFullPath($Workspace)
if (Test-Path -LiteralPath $Workspace) { throw '専用の新しい試験ディレクトリーを指定してください。' }
New-Item -ItemType Directory -Path $Workspace | Out-Null
Write-Output "candidate.sha256=$((Get-FileHash -LiteralPath $Candidate -Algorithm SHA256).Hash)"
Write-Output "probe.sha256=$((Get-FileHash -LiteralPath $TestProgram -Algorithm SHA256).Hash)"
Write-Output "script.sha256=$((Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash)"

function Set-SafetyFile([string]$Path, [string]$Value, [int]$Year = 2024) {
    New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($Path)) -Force | Out-Null
    [IO.File]::WriteAllBytes($Path,[Text.Encoding]::ASCII.GetBytes($Value))
    $stamp = [datetime]::new($Year,1,2,3,4,6,[DateTimeKind]::Utc)
    [IO.File]::SetCreationTimeUtc($Path,$stamp)
    [IO.File]::SetLastWriteTimeUtc($Path,$stamp)
    [IO.File]::SetLastAccessTimeUtc($Path,$stamp)
}
function Invoke-SafetyProbe([string]$Log, [string[]]$ProbeArguments, [int]$ResultCount = 1) {
    $rows = @(& $runner --timeout-seconds 30 $TestProgram --registry '' @ProbeArguments)
    $probeExit = $LASTEXITCODE
    [IO.File]::WriteAllLines($Log,[string[]]$rows,[Text.UTF8Encoding]::new($false))
    if ($probeExit -ne 0) { throw "試験プロセスが異常終了しました: $Log, exit=$probeExit" }
    if (@($rows -match '^result=').Count -ne $ResultCount) { throw "コマンド結果を確認できません: $Log" }
    return $rows
}
function Assert-SafetyFile([string]$Path, [string]$Value) {
    if (-not [IO.File]::Exists($Path) -or
        [Convert]::ToHexString([IO.File]::ReadAllBytes($Path)) -cne
        [Convert]::ToHexString([Text.Encoding]::ASCII.GetBytes($Value))) {
        throw "保持対象のファイルが削除・変更されました: $Path"
    }
}
function Get-SafetyCrc([byte[]]$Bytes) {
    [uint32]$crc = 0
    foreach ($value in $Bytes) {
        $crc = $crc -bxor $value
        for ($bit=0; $bit -lt 8; $bit++) { $crc = if ($crc -band 1) { ($crc -shr 1) -bxor 0xa001 } else { $crc -shr 1 } }
    }
    return $crc
}
function Read-SafetyArchive([string]$Path) {
    # 格納方式だけを使用し、検証対象 DLL の展開処理に依存せず全本文と CRC を読む。
    $bytes = [IO.File]::ReadAllBytes($Path)
    $members = @{}
    $offset = 0
    while ($offset + 1 -lt $bytes.Length) {
        if ($offset + 24 -gt $bytes.Length) { throw "途中で切れたヘッダー: $Path" }
        $level = $bytes[$offset+20]
        $headerSize = if ($level -eq 0) { [int]$bytes[$offset] + 2 } elseif ($level -eq 2) { [BitConverter]::ToUInt16($bytes,$offset) } else { throw "対象外のヘッダーレベル: $level" }
        $packed = [BitConverter]::ToUInt32($bytes,$offset+7)
        $original = [BitConverter]::ToUInt32($bytes,$offset+11)
        if ($headerSize -lt 24 -or $offset + $headerSize + $packed -ge $bytes.Length) { throw "本文の範囲が不正: $Path" }
        $method = [Text.Encoding]::ASCII.GetString($bytes,$offset+2,5)
        $name = ''; $directory = ''
        if ($level -eq 0) {
            $nameLength = $bytes[$offset+21]
            if (24 + $nameLength -gt $headerSize) { throw 'level-0 の名前が範囲外です。' }
            $name = [Text.Encoding]::ASCII.GetString($bytes,$offset+22,$nameLength)
            $crc = [BitConverter]::ToUInt16($bytes,$offset+22+$nameLength)
            $sum = 0
            for ($i=2; $i -lt $headerSize; $i++) { $sum = ($sum + $bytes[$offset+$i]) -band 255 }
            if ($sum -ne $bytes[$offset+1]) { throw 'level-0 ヘッダーチェックサムが不正です。' }
        } else {
            $crc = [BitConverter]::ToUInt16($bytes,$offset+21)
            $extension = $offset+24
            while ($true) {
                if ($extension + 2 -gt $offset + $headerSize) { throw '拡張ヘッダーの終端が範囲外です。' }
                $length = [BitConverter]::ToUInt16($bytes,$extension)
                if ($length -eq 0) { break }
                if ($length -lt 3 -or $extension + $length + 2 -gt $offset + $headerSize) { throw '拡張ヘッダーが範囲外です。' }
                if ($bytes[$extension+2] -eq 1) { $name = [Text.Encoding]::ASCII.GetString($bytes,$extension+3,$length-3) }
                if ($bytes[$extension+2] -eq 2) {
                    $directory = -join @($bytes[($extension+3)..($extension+$length-1)] | ForEach-Object { if ($_ -eq 255) { '/' } else { [char]$_ } })
                }
                $extension += $length
            }
        }
        $name = ($directory + $name).Replace('\','/')
        if (-not $name -or $members.ContainsKey($name)) { throw "空・重複した格納名: $Path/$name" }
        if ($method -eq '-lhd-') {
            if ($packed -ne 0 -or $original -ne 0) { throw 'ディレクトリーに本文があります。' }
        } elseif ($method -eq '-lh0-' -and $packed -eq $original) {
            $payload = [byte[]]::new($packed)
            [Array]::Copy($bytes,$offset+$headerSize,$payload,0,$packed)
            if ((Get-SafetyCrc $payload) -ne $crc) { throw "格納本文の CRC が不正: $Path/$name" }
            $members[$name] = [Convert]::ToHexString($payload)
        } else { throw "独立検証の対象外方式: $method" }
        $offset += $headerSize + $packed
    }
    if ($offset + 1 -ne $bytes.Length -or $bytes[$offset] -ne 0) { throw "書庫終端が不正: $Path" }
    return $members
}
function Assert-SafetyArchive([string]$Path, [hashtable]$Expected) {
    $actual = Read-SafetyArchive $Path
    if ($actual.Count -ne $Expected.Count) { throw "書庫の項目数が違います: $Path, actual=$($actual.Count), expected=$($Expected.Count)" }
    foreach ($name in $Expected.Keys) {
        if (-not $actual.ContainsKey($name) -or $actual[$name] -cne [Convert]::ToHexString([Text.Encoding]::ASCII.GetBytes($Expected[$name]))) {
            throw "保持対象の旧項目または格納した本文が違います: $Path/$name"
        }
    }
}
$old = @{ 'a.txt'='old-first-value'; 'z.txt'='old-last-value'; 'literal.txt'='old-parent-value' }
$seedSource = Join-Path $Workspace 'seed-source'
foreach ($name in $old.Keys) { Set-SafetyFile (Join-Path $seedSource $name) $old[$name] 2020 }
$seed = Join-Path $Workspace 'seed.lzh'
$seedCommand = "a -+ -jm0 -h0 -n1 -gm1 -y1 -x0 `"$seed`" `"$($seedSource.Replace('\','/'))/`" a.txt literal.txt z.txt"
$seedRows = @(Invoke-SafetyProbe (Join-Path $Workspace 'seed.txt') @('--base-command-probe',$Candidate,$seedCommand,'1041','1','W','none','0'))
if ($seedRows -notcontains 'result=0') { throw '元書庫の作成に失敗しました。' }
Assert-SafetyArchive $seed $old
$seedHash = (Get-FileHash -LiteralPath $seed -Algorithm SHA256).Hash
$count = 0
$caseSensitiveCount = 0
$caseSensitiveAvailable = $false
$fsutil = Get-Command fsutil.exe -ErrorAction SilentlyContinue
if ($fsutil) {
    $capabilityDirectory = Join-Path $Workspace 'case-sensitive-capability'
    New-Item -ItemType Directory -Path $capabilityDirectory | Out-Null
    # 生成した空ディレクトリーの属性だけを変更する。ACL 変更・権限昇格は行わない。
    $capabilityRows = @(& $fsutil.Source file setCaseSensitiveInfo $capabilityDirectory enable 2>&1)
    $caseSensitiveAvailable = $LASTEXITCODE -eq 0
    [IO.File]::WriteAllLines((Join-Path $Workspace 'case-sensitive-capability.txt'),[string[]]$capabilityRows,[Text.UTF8Encoding]::new($false))
}
if (-not $caseSensitiveAvailable) {
    if ($RequireCaseSensitive) { throw '大小文字を区別する試験ディレクトリーを有効にできません。' }
    Write-Output 'Case-sensitive guards unavailable in this environment; they are not counted as passed'
}
foreach ($api in $Apis) {
    foreach ($commandName in 'f','m') { foreach ($layout in $Layouts) { foreach ($selection in 'a.txt','*.txt') {
        $root = Join-Path $Workspace "$commandName-reject-$api-$layout-$count"
        New-Item -ItemType Directory -Path $root | Out-Null
        $archive = Join-Path $root 'result.lzh'
        Copy-Item -LiteralPath $seed -Destination $archive
        foreach ($name in $old.Keys) { Set-SafetyFile (Join-Path $root $name) "new-$name-value" }
        $command = "$commandName -+ -jm0 -h2 -n1 -gm1 -y1 -c1 `"$archive`" `"$($root.Replace('\','/'))/`" $selection"
        $rows = @(Invoke-SafetyProbe (Join-Path $root 'command.txt') @('--command-enum-probe',$Candidate,$command,$layout,'0','','1041','1',$api,'0'))
        $entries = @($rows -match '^enum.entry=')
        $expectedCallbacks = if ($selection -eq 'a.txt') { 1 } else { $old.Count }
        if ($rows -notcontains 'result=0' -or $entries.Count -ne $expectedCallbacks) { throw "コールバックの拒否条件へ到達していません: $root" }
        Assert-SafetyArchive $archive $old
        if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -cne $seedHash) { throw "拒否後に旧ヘッダー・本文のバイト列が変わりました: $root" }
        foreach ($name in $old.Keys) { Assert-SafetyFile (Join-Path $root $name) "new-$name-value" }
        $count++
    } } }
    Write-Output "Safety exceptions: $api FRESH/M rejection, $count preservation cases passed"
    foreach ($layout in $Layouts) {
        $root = Join-Path $Workspace "redirect-$api-$layout"
        New-Item -ItemType Directory -Path $root | Out-Null
        $archive = Join-Path $root 'result.lzh'
        Copy-Item -LiteralPath $seed -Destination $archive
        Set-SafetyFile (Join-Path $root 'a.txt') 'unarchived-original-value'
        $replacement = Join-Path $root 'replacement.bin'
        Set-SafetyFile $replacement 'redirected-input-value'
        $command = "m -+ -jm0 -h2 -n1 -gm1 -y1 -c1 `"$archive`" `"$($root.Replace('\','/'))/`" a.txt"
        $rows = @(Invoke-SafetyProbe (Join-Path $root 'command.txt') @('--command-enum-probe',$Candidate,$command,$layout,'1',$replacement,'1041','1',$api,'0'))
        if ($rows -notcontains 'result=0' -or @($rows -match '^enum.entry=').Count -ne 1) { throw "読込先の差し替えに失敗しました: $root" }
        $expected = $old.Clone()
        $expected['a.txt'] = 'redirected-input-value'
        Assert-SafetyArchive $archive $expected
        # 格納名が同じでも元の入力本文は格納していない。差し替え先も削除引数ではない。
        Assert-SafetyFile (Join-Path $root 'a.txt') 'unarchived-original-value'
        Assert-SafetyFile $replacement 'redirected-input-value'
        $count++
    }
    Write-Output "Safety exceptions: $api redirected move inputs, $count preservation cases passed"
    foreach ($layout in $Layouts) { foreach ($variant in 'upper','lower','sensitive-peer') {
        if ($variant -eq 'sensitive-peer' -and -not $caseSensitiveAvailable) { continue }
        $root = Join-Path $Workspace "alias-$api-$layout-$variant"
        New-Item -ItemType Directory -Path $root | Out-Null
        $name = if ($variant -eq 'sensitive-peer') { 'same.bin' } else { 'source-for-case-alias.data' }
        $original = Join-Path $root $name
        $payload = 'original-case-input-value'
        if ($variant -eq 'sensitive-peer') {
            $flagRows = @(& $fsutil.Source file setCaseSensitiveInfo $root enable 2>&1)
            if ($LASTEXITCODE -ne 0) { throw "試験ディレクトリーの大小文字設定が失敗しました: $root" }
        }
        Set-SafetyFile $original $payload
        $replacement = if ($variant -eq 'upper') { $original.ToUpperInvariant() } elseif ($variant -eq 'lower') { $original.ToLowerInvariant() } else { Join-Path $root 'SAME.BIN' }
        if ($variant -eq 'sensitive-peer') {
            Set-SafetyFile $replacement 'different-case-peer-value'
            if (@(Get-ChildItem -LiteralPath $root -File).Count -ne 2) { throw '大小文字が異なる別ファイルを作成できません。' }
            $payload = 'different-case-peer-value'
        } else { Assert-SafetyFile $replacement $payload }
        $archive = Join-Path $root 'result.lzh'
        Copy-Item -LiteralPath $seed -Destination $archive
        $command = "m -+ -jm0 -h2 -n1 -gm1 -y1 -c1 `"$archive`" `"$($root.Replace('\','/'))/`" $name"
        $rows = @(Invoke-SafetyProbe (Join-Path $root 'command.txt') @('--command-enum-probe',$Candidate,$command,$layout,'1',$replacement,'1041','1',$api,'0'))
        if ($rows -notcontains 'result=0' -or @($rows -match '^enum.entry=').Count -ne 1) { throw "大小文字の入力試験に失敗しました: $root" }
        $expected = $old.Clone()
        $expected[$name] = $payload
        Assert-SafetyArchive $archive $expected
        if ($variant -eq 'sensitive-peer') {
            Assert-SafetyFile $original 'original-case-input-value'
            Assert-SafetyFile $replacement 'different-case-peer-value'
            $caseSensitiveCount++
        } elseif ([IO.File]::Exists($original) -or [IO.File]::Exists($replacement)) {
            throw "同一ファイルの大小文字違いで正常な m が削除しません: $root"
        }
        $count++
    } }
    Write-Output "Safety exceptions: $api case aliases and distinct peers, $count preservation/control cases passed"
    foreach ($commandName in 'a','u','f') { foreach ($layout in 'none','w64') { foreach ($locked in 'a.txt','z.txt') {
        $root = Join-Path $Workspace "sharing-$api-$commandName-$layout-$count"
        New-Item -ItemType Directory -Path $root | Out-Null
        $archive = Join-Path $root 'result.lzh'
        Copy-Item -LiteralPath $seed -Destination $archive
        foreach ($name in 'a.txt','z.txt') { Set-SafetyFile (Join-Path $root $name) "new-$name-value" }
        $command = "$commandName -+ -jm0 -h2 -n1 -gm1 -y1 -c1 -jss1 `"$archive`" `"$($root.Replace('\','/'))/`" a.txt z.txt"
        $holder = [IO.File]::Open((Join-Path $root $locked),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        try {
            $rows = @(Invoke-SafetyProbe (Join-Path $root 'command.txt') @('--command-enum-probe',$Candidate,$command,$layout,'1','','1041','1',$api,'0'))
        } finally { $holder.Dispose() }
        # ここは保持保証だけを判定する。-jss1 の継続・戻り値・ログの互換性は別検証。
        $actual = Read-SafetyArchive $archive
        foreach ($name in $locked,'literal.txt') {
            if (-not $actual.ContainsKey($name) -or $actual[$name] -cne [Convert]::ToHexString([Text.Encoding]::ASCII.GetBytes($old[$name]))) {
                throw "共有エラーで旧項目が消失・変更しました: $root/$name"
            }
        }
        $other = if ($locked -eq 'a.txt') { 'z.txt' } else { 'a.txt' }
        $allowedOther = @($old[$other],"new-$other-value") | ForEach-Object { [Convert]::ToHexString([Text.Encoding]::ASCII.GetBytes($_)) }
        if ($actual.Count -ne $old.Count -or $actual[$other] -cnotin $allowedOther) { throw "共有エラーで別項目が失われました: $root" }
        foreach ($name in 'a.txt','z.txt') { Assert-SafetyFile (Join-Path $root $name) "new-$name-value" }
        $count++
    } } }
    Write-Output "Safety exceptions: $api jss1 sharing, $count preservation cases passed"
    foreach ($variant in 'parent-unreadable','exclude-all','exclude-mixed','normal-move','empty-move') {
        $root = Join-Path $Workspace "move-$api-$variant"
        New-Item -ItemType Directory -Path $root | Out-Null
        $archive = Join-Path $root 'result.lzh'
        Copy-Item -LiteralPath $seed -Destination $archive
        $expected = $old.Clone()
        $inputs = @{}
        $deleted = ''
        $caller = $root
        if ($variant -eq 'parent-unreadable') {
            $caller = Join-Path $root 'caller'
            New-Item -ItemType Directory -Path $caller,(Join-Path $caller 'source') | Out-Null
            $inputs['source/literal.txt'] = 'unrelated-parent-value'
            $inputs['caller/..source/literal.txt'] = 'search-only-value'
            $command = "m -+ -jm0 -h2 -n1 -gm1 -y1 -c1 -x0 `"$archive`" `"..\source\`" `"*.txt`""
        } elseif ($variant -in 'normal-move','empty-move') {
            $inputs['move.bin'] = if ($variant -eq 'empty-move') { '' } else { 'successfully-archived-value' }
            $expected['move.bin'] = $inputs['move.bin']
            $deleted = 'move.bin'
            $command = "m -+ -jm0 -h2 -n1 -gm1 -y1 -x0 `"$archive`" `"$($root.Replace('\','/'))/`" move.bin"
        } else {
            $inputs['tree/a.txt'] = 'excluded-first-value'
            $inputs['tree/sub/z.txt'] = 'excluded-nested-value'
            if ($variant -eq 'exclude-mixed') {
                $inputs['tree/keep.bin'] = 'successfully-archived-value'
                $expected['tree/keep.bin'] = $inputs['tree/keep.bin']
                $deleted = 'tree/keep.bin'
            }
            $command = "m -+ -jm0 -h2 -n1 -gm1 -y1 -r1 -x1 -jx*.txt `"$archive`" `"$($root.Replace('\','/'))/`" `"tree/*`""
        }
        foreach ($name in $inputs.Keys) { Set-SafetyFile (Join-Path $root $name) $inputs[$name] }
        Push-Location -LiteralPath $caller
        try { $rows = @(Invoke-SafetyProbe (Join-Path $root 'command.txt') @('--base-command-probe',$Candidate,$command,'1041','1',$api,'w64','0')) }
        finally { Pop-Location }
        if ($rows -notcontains 'directory-preserved=1') { throw "カレントディレクトリーが変わりました: $root" }
        Assert-SafetyArchive $archive $expected
        foreach ($name in $inputs.Keys) {
            $path = Join-Path $root $name
            if ($name -eq $deleted) {
                if ([IO.File]::Exists($path) -or $rows -notcontains 'result=0') { throw "正常な m の削除が実行されませんでした: $path" }
            } else { Assert-SafetyFile $path $inputs[$name] }
        }
        $count++
    }
    Write-Output "Safety exceptions: $api move sources, $count preservation/control cases passed"
    foreach ($layout in $Layouts) {
        $root = Join-Path $Workspace "recovery-$api-$layout"
        New-Item -ItemType Directory -Path $root | Out-Null
        $archive = Join-Path $root 'result.lzh'
        Copy-Item -LiteralPath $seed -Destination $archive
        $inputPath = Join-Path $root 'a.txt'
        Set-SafetyFile $inputPath 'new-first-value'
        [IO.File]::SetAttributes($inputPath,[IO.FileAttributes]::ReadOnly -bor [IO.FileAttributes]::Archive)
        $command = "m -+ -jm0 -h0 -n1 -gm1 -y1 -c1 `"$archive`" `"$($root.Replace('\','/'))/`" a.txt"
        # 初回は格納後の削除に失敗。次の拒否に格納済み集合が漏れると再び削除エラーになる。
        $rows = @(Invoke-SafetyProbe (Join-Path $root 'sequence.txt') @('--enum-sequence-probe',$Candidate,$layout,'1041','1',$api,$command,'@reject',$command) 2)
        if ((@($rows -match '^result=') -join ',') -cne 'result=32828,result=0') { throw "削除失敗後の拒否・再利用が違います: $root" }
        $expected = $old.Clone()
        $expected['a.txt'] = 'new-first-value'
        Assert-SafetyArchive $archive $expected
        Assert-SafetyFile $inputPath 'new-first-value'
        $count++
    }
    Write-Output "Safety exceptions: $api same-DLL reuse, $count preservation/control cases passed"
}
Write-Output "Safety exceptions: $count candidate-only cases passed; case-sensitive-guards=$caseSensitiveCount; original data-loss behavior intentionally not reproduced"
