[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Workspace,
    [ValidateSet('legacy','A','W')][string[]]$CommandApis = @('legacy','A','W'),
    [ValidateSet('enum','progress')][string[]]$Profiles = @('enum','progress')
)
$ErrorActionPreference = 'Stop'
$TestProgram = (Resolve-Path -LiteralPath $TestProgram).Path
$Oracle = (Resolve-Path -LiteralPath $Oracle).Path
$Candidate = (Resolve-Path -LiteralPath $Candidate).Path
$runner = Join-Path (Split-Path -Parent $TestProgram) 'DesktopRunner.exe'
$Workspace = [IO.Path]::GetFullPath($Workspace)
if (Test-Path -LiteralPath $Workspace) { throw '新しい検証用ディレクトリーを指定してください' }
if (!(Test-Path -LiteralPath $runner -PathType Leaf)) { throw 'DesktopRunner が必要です' }
New-Item -ItemType Directory -Path $Workspace | Out-Null
$hashes = @{}
foreach ($path in $TestProgram,$runner,$Oracle,$Candidate) {
    $hashes[$path] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    Write-Host "LZ5 environment: $path, SHA256=$($hashes[$path])"
}
Write-Host "LZ5 compression workspace: $Workspace"

function Assert-Lz5Packets([byte[]]$Body,[byte[]]$Payload,[bool]$RequireZeroInitialPadding) {
    # 製品の復号器と独立して、辞書参照・8 トークン境界・未使用領域を検査する。
    $dictionary = [byte[]]::new(4096)
    [Array]::Fill($dictionary,[byte]32)
    for ($i=0; $i -lt 256; $i++) {
        for ($j=0; $j -lt 13; $j++) { $dictionary[$i*13+18+$j] = $i }
        $dictionary[256*13+18+$i] = $i
        $dictionary[256*13+256+18+$i] = 255-$i
    }
    for ($i=0; $i -lt 128; $i++) { $dictionary[256*13+512+18+$i] = 0 }
    $cursor = 0
    $produced = 0
    $previous = $null
    $initial = [Collections.Generic.List[int]]::new()
    $priorCount = 0
    while ($cursor -lt $Body.Length) {
        if ($produced -ge $Payload.Length) { throw '本文の終了後に余分な LZ5 パケットがあります' }
        $flags = $Body[$cursor++]
        $current = [byte[]]::new(8)
        for ($slot=0; $slot -lt 8; $slot++) {
            if ($cursor -ge $Body.Length) { throw 'LZ5 の 8 トークンが揃っていません' }
            $literal = ($flags -band (1 -shl $slot)) -ne 0
            $offset = $cursor
            $first = $Body[$cursor++]
            $length = 1
            $position = 0
            if ($literal) { $current[$slot] = $first }
            else {
                if ($cursor -ge $Body.Length) { throw 'LZ5 の辞書参照が途中で終わっています' }
                $second = $Body[$cursor++]
                $current[$slot] = $second -band 15
                $length = ($second -band 15)+3
                $position = ($first + (($second -band 240) -shl 4) + 18) -band 4095
                if ($length -gt 17) { throw '原版の最大一致長 17 を超えています' }
            }
            if ($produced -eq $Payload.Length) {
                if (!$literal) { throw 'LZ5 の未使用スロットが辞書参照になっています' }
                if ($null -eq $previous) {
                    # 原版の未初期化値を記録・要求せず、候補だけゼロを必須にする。
                    if ($RequireZeroInitialPadding -and $first -ne 0) { throw 'LZ5 の初回未使用スロットがゼロではありません' }
                    $initial.Add($offset)
                } else {
                    if ($first -ne $previous[$slot]) { throw 'LZ5 の末尾が同じ項目の直前パケットと違います' }
                    $priorCount++
                }
                continue
            }
            if ($produced+$length -gt $Payload.Length) { throw 'LZ5 トークンが元入力の終端を超えています' }
            for ($i=0; $i -lt $length; $i++) {
                $value = if ($literal) { $first } else { $dictionary[($position+$i) -band 4095] }
                if ($value -ne $Payload[$produced]) { throw "LZ5 本文が元入力と違います: offset=$produced" }
                $dictionary[$produced -band 4095] = $value
                $produced++
            }
        }
        $previous = $current
    }
    if ($produced -ne $Payload.Length -or $cursor -ne $Body.Length) { throw 'LZ5 の出力サイズが違います' }
    return [pscustomobject]@{ Initial=[int[]]$initial.ToArray(); Previous=$priorCount }
}

function Read-CompressedMember([string]$Archive,[byte[]]$Payload,[bool]$RequireZeroInitialPadding) {
    $bytes = [IO.File]::ReadAllBytes($Archive)
    if ($bytes.Length -lt 27 -or $bytes[20] -ne 2) { throw 'level 2 の単一項目が必要です' }
    $header = [int][BitConverter]::ToUInt16($bytes,0)
    $packed = [int][BitConverter]::ToUInt32($bytes,7)
    $original = [int][BitConverter]::ToUInt32($bytes,11)
    if ($header -lt 26 -or $header+$packed+1 -ne $bytes.Length -or $bytes[-1] -ne 0 -or $original -ne $Payload.Length) {
        throw '書庫ヘッダーの本文境界が不正です'
    }
    $method = [Text.Encoding]::ASCII.GetString($bytes,2,5)
    $body = [byte[]]::new($packed)
    [Array]::Copy($bytes,$header,$body,0,$packed)
    $packets = [pscustomobject]@{ Initial=[int[]]@(); Previous=0 }
    if ($method -ceq '-lz5-') { $packets = Assert-Lz5Packets $body $Payload $RequireZeroInitialPadding }
    return [pscustomobject]@{ Method=$method; Packed=$packed; Original=$original; Body=$body; Packets=$packets }
}

# 同じ DLL を保持し、別サイズ・格納へのフォールバック・別方式を挟んで短い入力へ戻る。
$reuse = @(
    @('repeat',17,'jm8'), @('repeat',17,'jm8'), @('repeat',8191,'jm8'),
    @('repeat',17,'jm8'), @('repeat',33,'jm8'), @('repeat',65,'jm8'),
    @('block65',8193,'jm8'), @('repeat',17,'jm8'), @('random',4096,'jm8'),
    @('repeat',17,'jm8'), @('repeat',8191,'jm2'), @('repeat',17,'jm8')
)
$boundaries = @(
    @('repeat',0,'jm8'), @('repeat',1,'jm8'), @('repeat',7,'jm8'), @('repeat',8,'jm8'),
    @('repeat',9,'jm8'), @('repeat',10,'jm8'), @('repeat',11,'jm8'), @('repeat',16,'jm8'),
    @('repeat',18,'jm8'), @('repeat',99,'jm8'), @('repeat',100,'jm8'), @('repeat',101,'jm8'),
    @('repeat',4095,'jm8'), @('repeat',4096,'jm8'), @('repeat',4097,'jm8'), @('repeat',8192,'jm8'),
    @('block65',4095,'jm8'), @('block65',4096,'jm8'), @('block65',4097,'jm8'),
    @('block65',8191,'jm8'), @('block65',8192,'jm8'),
    @('random',7,'jm8'), @('random',8,'jm8'), @('random',9,'jm8'), @('random',17,'jm8'),
    @('random',8193,'jm8'), @('alphabet',8193,'jm8'), @('block4096',8193,'jm8')
)
$time = [datetime]::new(2024,1,2,3,4,6,[DateTimeKind]::Utc)
$pairCount = 0
$exactCount = 0
$paddingCount = 0
$priorCount = 0
$lz5Count = 0
$payloadCount = 0
foreach ($api in $CommandApis) { foreach ($profile in $Profiles) {
    $specifications = @($reuse)
    if ($profile -eq 'enum') { $specifications += $boundaries }
    $sets = @{}
    foreach ($side in 'oracle','candidate') {
        $dll = if ($side -eq 'oracle') { $Oracle } else { $Candidate }
        $profileRoot = Join-Path $Workspace "$api-$profile-$side"
        New-Item -ItemType Directory -Path $profileRoot | Out-Null
        $fixtures = [Collections.Generic.List[object]]::new()
        $commands = [Collections.Generic.List[string]]::new()
        for ($step=0; $step -lt $specifications.Count; $step++) {
            $pattern,$size,$method = $specifications[$step]
            $root = Join-Path $profileRoot ("{0:D2}-$pattern-$size-$method" -f $step)
            New-Item -ItemType Directory -Path $root | Out-Null
            $data = [byte[]]::new($size)
            if ($pattern -eq 'repeat') { [Array]::Fill($data,[byte]65) }
            elseif ($pattern -eq 'random') { [Random]::new(81723).NextBytes($data) }
            elseif ($pattern -eq 'alphabet') {
                for ($i=0; $i -lt $size; $i++) { $data[$i] = 65+($i % 26) }
            } else {
                $blockSize = [int]$pattern.Substring(5)
                $block = [byte[]]::new($blockSize)
                [Random]::new(81723).NextBytes($block)
                for ($i=0; $i -lt $size; $i++) { $data[$i] = $block[$i % $blockSize] }
            }
            $inputPath = Join-Path $root 'a.bin'
            [IO.File]::WriteAllBytes($inputPath,$data)
            [IO.File]::SetCreationTimeUtc($inputPath,$time)
            [IO.File]::SetLastWriteTimeUtc($inputPath,$time)
            [IO.File]::SetLastAccessTimeUtc($inputPath,$time)
            $archive = Join-Path $root 'result.lzh'
            $commands.Add("a -+ -$method -h2 -n1 -gm1 -y1 `"$archive`" `"$($root.Replace('\','/'))/`" a.bin")
            $fixtures.Add([pscustomobject]@{
                Root=$root; Input=$inputPath; Archive=$archive; Data=$data; Method=$method
                Identity="$pattern-$size-$method"; Hash=(Get-FileHash -LiteralPath $inputPath -Algorithm SHA256).Hash
            })
        }
        $arguments = if ($profile -eq 'enum') {
            @('--registry','','--enum-sequence-probe',$dll,'w64','1041','1',$api)
        } else {
            @('--registry','','--progress-sequence-probe',$dll,'w64','1041','1',$api,'w64')
        }
        $rows = @(& $runner --timeout-seconds 60 $TestProgram @arguments @commands 2>&1 | ForEach-Object { "$_" })
        $code = $LASTEXITCODE
        [IO.File]::WriteAllLines((Join-Path $profileRoot 'commands.txt'),[string[]]$rows,[Text.UTF8Encoding]::new($false))
        $results = @($rows -match '^result=')
        if ($code -ne 0 -or $results.Count -ne $fixtures.Count -or @($results -cne 'result=0').Count) {
            throw "LZ5 の連続圧縮が失敗しました: $api/$profile/$side/exit=$code"
        }
        $sets[$side] = $fixtures
    }
    $stable = @{}
    for ($step=0; $step -lt $specifications.Count; $step++) {
        $members = @()
        foreach ($side in 'oracle','candidate') {
            $fixture = $sets[$side][$step]
            $member = Read-CompressedMember $fixture.Archive $fixture.Data ($side -eq 'candidate')
            $allowed = if ($fixture.Method -eq 'jm8') { @('-lh0-','-lz5-') } else { @('-lh0-','-lh5-') }
            if ($member.Method -cnotin $allowed) { throw "予期しない格納方式です: $api/$profile/$step/$side" }
            $archiveHash = (Get-FileHash -LiteralPath $fixture.Archive -Algorithm SHA256).Hash
            $readers = @()
            foreach ($readerSide in 'oracle','candidate') {
                $reader = if ($readerSide -eq 'oracle') { $Oracle } else { $Candidate }
                $rows = @(& $runner --timeout-seconds 30 $TestProgram --registry '' --legacy-payload-probe $reader $fixture.Archive $fixture.Input 2>&1 | ForEach-Object { "$_" })
                $code = $LASTEXITCODE
                [IO.File]::WriteAllLines((Join-Path $fixture.Root "memory-$readerSide.txt"),[string[]]$rows,[Text.UTF8Encoding]::new($false))
                if ($code -ne 0 -or $rows.Count -ne 3 -or @($rows -notmatch ',payload=1,prefix=1,tail=1,guard=1$').Count) {
                    throw "LZ5 の相互展開・本文・ガードに失敗しました: $api/$profile/$step/$side/$readerSide"
                }
                $readers += ,$rows
                $payloadCount += 3
            }
            if (@(Compare-Object $readers[0] $readers[1] -SyncWindow 0).Count) { throw "LZ5 の展開結果・メタデータが違います: $api/$profile/$step/$side" }
            if ((Get-FileHash -LiteralPath $fixture.Archive -Algorithm SHA256).Hash -cne $archiveHash -or
                (Get-FileHash -LiteralPath $fixture.Input -Algorithm SHA256).Hash -cne $fixture.Hash) { throw 'LZ5 の書庫または入力が変更されました' }
            $members += $member
        }
        $left,$right = $members
        if ($left.Method -cne $right.Method -or $left.Packed -ne $right.Packed -or $left.Original -ne $right.Original -or
            ($left.Packets.Initial -join ',') -cne ($right.Packets.Initial -join ',')) { throw "LZ5 の方式・サイズ・未使用領域が一致しません: $api/$profile/$step" }
        for ($i=0; $i -lt $left.Body.Length; $i++) {
            if ($i -notin $left.Packets.Initial -and $left.Body[$i] -ne $right.Body[$i]) {
                throw "LZ5 の圧縮本文が一致しません: $api/$profile/$step/offset=$i"
            }
        }
        if (!$left.Packets.Initial.Count) { $exactCount++ }
        if ($left.Method -ceq '-lz5-') { $lz5Count++ }
        $paddingCount += $right.Packets.Initial.Count
        $priorCount += $right.Packets.Previous
        $identity = $sets['candidate'][$step].Identity
        $bodyHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($right.Body))
        if ($stable.ContainsKey($identity) -and $stable[$identity] -cne $bodyHash) { throw "LZ5 の DLL 再利用で圧縮本文が変化しました: $api/$profile/$step" }
        $stable[$identity] = $bodyHash
        $pairCount++
        if ($pairCount % 10 -eq 0) { Write-Host "LZ5 compression: $pairCount body pairs, $payloadCount full-payload API checks passed" }
    }
} }
if (!$pairCount -or !$lz5Count -or !$paddingCount -or !$priorCount) { throw 'LZ5 の必要な圧縮・末尾条件が実行されていません' }
foreach ($path in $hashes.Keys) {
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $hashes[$path]) { throw "検証中に実行ファイルが変更されました: $path" }
}
Write-Host "LZ5 compression: $pairCount body pairs ($exactCount exact, $($pairCount-$exactCount) with only initial unused slots excluded), $lz5Count independent LZ5 decodes per DLL, $paddingCount zero initial slots, $priorCount previous-packet slots, $payloadCount full-payload/guard API checks passed"
