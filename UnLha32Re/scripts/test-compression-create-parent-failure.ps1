[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$RunnerPath,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Workspace,
    [ValidateNotNullOrEmpty()][ValidateSet('a','u','m','j')][string[]]$Commands = @('a','u','m','j'),
    [ValidateNotNullOrEmpty()][ValidateSet('legacy','A','W')][string[]]$Apis = @('legacy','A','W'),
    [int[]]$Locales = @(1041,1033),
    [ValidateSet(0,1)][int[]]$UnicodeModes = @(0),
    [string[]]$CaseNames = @()
)

$ErrorActionPreference = 'Stop'
$TestProgram = (Resolve-Path -LiteralPath $TestProgram).Path
$RunnerPath = (Resolve-Path -LiteralPath $RunnerPath).Path
$Oracle = (Resolve-Path -LiteralPath $Oracle).Path
$Candidate = (Resolve-Path -LiteralPath $Candidate).Path
$root = [IO.Path]::GetFullPath($Workspace)
if (Test-Path -LiteralPath $root) { throw '新規書庫の親欠落試験には新しい作業先が必要です。' }
foreach ($values in @($Commands,$Apis,$Locales,$UnicodeModes)) {
    if (@($values | Select-Object -Unique).Count -ne @($values).Count) {
        throw '試験軸に重複した値があります。'
    }
}

$definitions = @(
    @{ Name = 'missing-parent'; ExistingParent = $false },
    @{ Name = 'existing-parent'; ExistingParent = $true }
)
if ($CaseNames.Count) {
    $selected = @($CaseNames | ForEach-Object { $_.Split(',') })
    if (@($selected | Select-Object -Unique).Count -ne $selected.Count) {
        throw '条件の重複指定はできません。'
    }
    foreach ($name in $selected) {
        if ($name -notin $definitions.Name) { throw "未知の条件: $name" }
    }
    $definitions = @($definitions | Where-Object { $_.Name -in $selected })
}
if (!$definitions.Count) { throw '親欠落試験の条件が空です。' }
foreach ($locale in $Locales) {
    if ($locale -notin @(1033,1041)) { throw "未対応のロケールです: $locale" }
}

New-Item -ItemType Directory -Path $root | Out-Null
$hashes = @{}
foreach ($path in $TestProgram,$RunnerPath,$Oracle,$Candidate,$PSCommandPath) {
    $hashes[$path] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
}
[IO.File]::WriteAllText((Join-Path $root 'environment.json'), ($hashes | ConvertTo-Json),
    [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $root 'plan.json'),
    (@{ Commands = $Commands; Apis = $Apis; Locales = $Locales; UnicodeModes = $UnicodeModes; Conditions = $definitions.Name } | ConvertTo-Json),
    [Text.UTF8Encoding]::new($false))

function Invoke-BaseProbe([string]$Dll, [string]$Command, [int]$Locale, [int]$UnicodeMode,
                           [string]$Api, [string]$Folder, [string]$LogPath) {
    $arguments = @('--base-command-probe',$Dll,$Command,[string]$Locale,[string]$UnicodeMode,$Api)
    [IO.File]::WriteAllText((Join-Path $Folder 'invocation.json'),
        ($arguments | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    Push-Location -LiteralPath $Folder
    try {
        $rows = @(& $RunnerPath --timeout-seconds 30 $TestProgram --registry '' @arguments 2>&1 |
            ForEach-Object { "$_" })
        $exit = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    [IO.File]::WriteAllLines($LogPath, [string[]]$rows, [Text.UTF8Encoding]::new($false))
    if ($exit -ne 0) { throw "新規書庫の親欠落プローブが停止しました: $exit / $LogPath" }
    return ,$rows
}

function Assert-Scalar([string[]]$Rows, [string]$Prefix, [int]$Expected, [string]$Label) {
    $matches = @($Rows | Where-Object { $_ -ceq "$Prefix=$Expected" })
    if ($matches.Count -ne 1) { throw "$Label の $Prefix が不一致です。" }
}

function Normalize-Rows([string[]]$Rows, [string]$Folder) {
    $slash = $Folder.Replace('\','/')
    $escaped = $Folder.Replace('\','\\')
    @($Rows | ForEach-Object { $_.Replace($escaped,'<ROOT>').Replace($slash,'<ROOT>').Replace($Folder,'<ROOT>') })
}

function Get-State([string]$Path) {
    if (!(Test-Path -LiteralPath $Path)) { return $null }
    $stream = [IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
    $stream.Dispose()
    $item = Get-Item -LiteralPath $Path -Force
    [pscustomobject]@{
        Hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
        Length = $item.Length
        Creation = $item.CreationTimeUtc.Ticks
        Write = $item.LastWriteTimeUtc.Ticks
        Attributes = [int]$item.Attributes
    }
}

$sourceSeed = Join-Path $root 'join-source.lzh'
$sourceSeedInput = Join-Path $root 'join-source-input'
New-Item -ItemType Directory -Path $sourceSeedInput | Out-Null
[IO.File]::WriteAllText((Join-Path $sourceSeedInput 'a.txt'),'join-source-body',[Text.UTF8Encoding]::new($false))
$sourceSeedCommand = 'a -+ -n1 -gm1 -y1 -h2 "' + $sourceSeed + '" "' +
    $sourceSeedInput.Replace('\','/') + '/" a.txt'
$seedFolder = Join-Path $root 'seed'
New-Item -ItemType Directory -Path $seedFolder | Out-Null
$seedRows = Invoke-BaseProbe $Oracle $sourceSeedCommand 1041 0 'W' $seedFolder (Join-Path $root 'seed.log')
if ('result=0' -cnotin $seedRows -or !(Test-Path -LiteralPath $sourceSeed)) {
    throw '連結用の基準書庫を作成できません。'
}
$sourceSeedHash = (Get-FileHash -LiteralPath $sourceSeed -Algorithm SHA256).Hash

$records = [Collections.Generic.List[object]]::new()
$pairCount = 0
$modes = @{}
foreach ($api in $Apis) {
    $modes[$api] = if ($api -eq 'W') { $UnicodeModes } else { @(0) }
}
foreach ($command in $Commands) {
    foreach ($locale in $Locales) {
        foreach ($api in $Apis) {
            foreach ($unicodeMode in $modes[$api]) {
                foreach ($definition in $definitions) {
                    $pair = @{}
                    foreach ($side in 'oracle','reimpl') {
                        $label = "$command-$locale-$unicodeMode-$api-$($definition.Name)-$side"
                        $folder = Join-Path $root $label
                        New-Item -ItemType Directory -Path $folder | Out-Null
                        $sourceDirectory = Join-Path $folder 'source'
                        New-Item -ItemType Directory -Path $sourceDirectory | Out-Null
                        $sourceFile = Join-Path $sourceDirectory 'a.txt'
                        [IO.File]::WriteAllText($sourceFile,'parent-failure-body',[Text.UTF8Encoding]::new($false))
                        $sourceHash = (Get-FileHash -LiteralPath $sourceFile -Algorithm SHA256).Hash
                        $destinationParent = Join-Path $folder 'missing-parent'
                        if ($definition.ExistingParent) { New-Item -ItemType Directory -Path $destinationParent | Out-Null }
                        $destination = Join-Path $destinationParent 'out.lzh'
                        $joinSource = Join-Path $folder 'join-source.lzh'
                        if ($command -eq 'j') { Copy-Item -LiteralPath $sourceSeed -Destination $joinSource }
                        $beforeFiles = @(Get-ChildItem -LiteralPath $folder -Recurse -File -Force |
                            ForEach-Object { $_.FullName.Substring($folder.Length + 1) } | Sort-Object)
                        $line = if ($command -eq 'j') {
                            'j -+ -n1 -gm1 -y1 -h2 "' + $destination + '" "' + $joinSource + '"'
                        } else {
                            $command + ' -+ -n1 -gm1 -y1 -h2 "' + $destination + '" "' +
                                $sourceDirectory.Replace('\','/') + '/" a.txt'
                        }
                        $dll = if ($side -eq 'oracle') { $Oracle } else { $Candidate }
                        $log = Join-Path $folder 'command.log'
                        $started = [datetime]::UtcNow.Ticks
                        $rows = Invoke-BaseProbe $dll $line $locale $unicodeMode $api $folder $log
                        $ended = [datetime]::UtcNow.Ticks
                        Assert-Scalar $rows 'result' ($(if ($definition.ExistingParent) { 0 } else { 32792 })) $label
                        Assert-Scalar $rows 'win32-error' 0 $label
                        Assert-Scalar $rows 'compat-error' ($(if ($definition.ExistingParent) { 0 } else { 32792 })) $label
                        $expectedSystem = if ($definition.ExistingParent -and $command -eq 'm') { 18 }
                            elseif ($definition.ExistingParent) { 38 } else { 3 }
                        Assert-Scalar $rows 'compat-system-error' $expectedSystem $label
                        Assert-Scalar $rows 'directory-preserved' 1 $label
                        $state = Get-State $destination
                        if ($definition.ExistingParent) {
                            if (!$state) { throw "${label}: 正常な親ディレクトリで書庫が作成されません。" }
                        } elseif ($state -or (Test-Path -LiteralPath $destinationParent)) {
                            throw "${label}: 親欠落時に出力またはディレクトリが残りました。"
                        }
                        if (!$definition.ExistingParent -and $command -ne 'j') {
                            $afterSource = Get-State $sourceFile
                            if (!$afterSource -or $afterSource.Hash -cne $sourceHash) {
                                throw "${label}: 親欠落時に入力ファイルが変化しました。"
                            }
                        } elseif ($command -eq 'j') {
                            $afterJoinSource = Get-State $joinSource
                            if (!$afterJoinSource -or $afterJoinSource.Hash -cne $sourceSeedHash) {
                                throw "${label}: 連結元書庫が変化しました。"
                            }
                        }
                        $afterFiles = @(Get-ChildItem -LiteralPath $folder -Recurse -File -Force |
                            Where-Object { $_.Name -notin @('command.log','result.json','invocation.json') } |
                            ForEach-Object { $_.FullName.Substring($folder.Length + 1) } | Sort-Object)
                        if (!$definition.ExistingParent -and ($afterFiles | Where-Object { $_ -notin $beforeFiles }).Count) {
                            throw "${label}: 親欠落時に一時ファイルが残りました。"
                        }
                        $pair[$side] = @(Normalize-Rows $rows $folder)
                        $record = [pscustomobject]@{
                            Command = $command; Locale = $locale; UnicodeMode = $unicodeMode; Api = $api
                            Condition = $definition.Name; Side = $side; Result = $rows; Destination = $state
                            Started = $started; Ended = $ended
                        }
                        $records.Add($record)
                        [IO.File]::WriteAllText((Join-Path $folder 'result.json'),
                            ($record | ConvertTo-Json -Depth 7),[Text.UTF8Encoding]::new($false))
                    }
                    $difference = @(Compare-Object $pair.oracle $pair.reimpl -SyncWindow 0)
                    if ($difference.Count) {
                        [IO.File]::WriteAllText((Join-Path $root "$command-$locale-$unicodeMode-$api-$($definition.Name).diff.log"),
                            ($difference | Format-List | Out-String -Width 2000),[Text.UTF8Encoding]::new($false))
                        throw "新規書庫の親欠落出力が不一致です: $command/$locale/$unicodeMode/$api/$($definition.Name)"
                    }
                    $pairCount++
                    if (($pairCount % 4) -eq 0) {
                        Write-Host "Compression create-parent: $pairCount comparisons passed"
                    }
                }
            }
        }
    }
}
if ((Get-FileHash -LiteralPath $sourceSeed -Algorithm SHA256).Hash -cne $sourceSeedHash) {
    throw '連結用の基準書庫が検証中に変化しました。'
}
foreach ($path in $hashes.Keys) {
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $hashes[$path]) {
        throw "検証中にファイルが変化しました: $path"
    }
}
[IO.File]::WriteAllText((Join-Path $root 'results.json'),($records | ConvertTo-Json -Depth 8),
    [Text.UTF8Encoding]::new($false))
Write-Host "Compression create-parent: $pairCount command/API/locale/condition comparisons passed."
