[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Workspace,
    [ValidateSet('legacy','A','W')][string[]]$CommandApis = @('legacy','A','W'),
    [string[]]$CaseNames = @()
)

$ErrorActionPreference = 'Stop'
$TestProgram = (Resolve-Path -LiteralPath $TestProgram).Path
$Oracle = (Resolve-Path -LiteralPath $Oracle).Path
$Candidate = (Resolve-Path -LiteralPath $Candidate).Path
$runner = Join-Path (Split-Path -Parent $TestProgram) 'DesktopRunner.exe'
$Workspace = [IO.Path]::GetFullPath($Workspace)
if (Test-Path -LiteralPath $Workspace) { throw '新しい検証用ディレクトリーを指定してください' }
if (!(Test-Path -LiteralPath $runner -PathType Leaf)) { throw 'DesktopRunner が必要です' }
& $runner --require-isolated
if ($LASTEXITCODE -ne 0) { throw 'LH3 検証は DesktopRunner の非表示デスクトップ内で実行してください' }
New-Item -ItemType Directory -Path $Workspace | Out-Null

$hashes = @{}
foreach ($path in $TestProgram,$runner,$Oracle,$Candidate) {
    $hashes[$path] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    Write-Host "LH3 environment: $path, SHA256=$($hashes[$path])"
}
Write-Host "LH3 compression workspace: $Workspace"

function New-TestData([string]$Pattern,[int]$Size) {
    $data = [byte[]]::new($Size)
    if ($Pattern -eq 'repeat') {
        [Array]::Fill($data,[byte]65)
    } elseif ($Pattern -eq 'random') {
        [Random]::new(81723).NextBytes($data)
    } elseif ($Pattern.StartsWith('block')) {
        $blockSize = [int]$Pattern.Substring(5)
        $block = [byte[]]::new($blockSize)
        [Random]::new(81723 + $blockSize).NextBytes($block)
        for ($i=0; $i -lt $Size; $i++) { $data[$i] = $block[$i % $blockSize] }
    } elseif ($Pattern -eq 'two-groups') {
        $first = [byte[]]::new(65)
        $second = [byte[]]::new(129)
        [Random]::new(1103).NextBytes($first)
        [Random]::new(7727).NextBytes($second)
        $cursor = 0
        while ($cursor -lt $Size) {
            foreach ($block in @($first,$second)) {
                for ($repeat=0; $repeat -lt 8 -and $cursor -lt $Size; $repeat++) {
                    for ($i=0; $i -lt $block.Length -and $cursor -lt $Size; $i++) {
                        $data[$cursor++] = $block[$i]
                    }
                }
            }
        }
    } elseif ($Pattern -eq 'runs') {
        for ($i=0; $i -lt $Size; $i++) {
            $data[$i] = 65 + (([int][Math]::Floor($i / 1024)) % 4)
        }
    } elseif ($Pattern -eq 'paired4096') {
        $cursor = 0
        for ($pair=0; $pair -lt 16; $pair++) {
            $block = [byte[]]::new(4096)
            [Random]::new(91001 + $pair * 7919 + 4096).NextBytes($block)
            [Array]::Copy($block,0,$data,$cursor,$block.Length)
            $cursor += $block.Length
            [Array]::Copy($block,0,$data,$cursor,$block.Length)
            $cursor += $block.Length
        }
    } else {
        throw "未知の LH3 入力パターンです: $Pattern"
    }
    return ,$data
}

function Read-CompressedMember([string]$Archive,[byte[]]$Payload) {
    $bytes = [IO.File]::ReadAllBytes($Archive)
    if ($bytes.Length -lt 27 -or $bytes[20] -ne 2) { throw 'level 2 の単一項目が必要です' }
    $header = [int][BitConverter]::ToUInt16($bytes,0)
    $packed = [int][BitConverter]::ToUInt32($bytes,7)
    $original = [int][BitConverter]::ToUInt32($bytes,11)
    if ($header -lt 26 -or $header + $packed + 1 -ne $bytes.Length -or
        $bytes[-1] -ne 0 -or $original -ne $Payload.Length) {
        throw 'LH3 書庫ヘッダーの本文境界が不正です'
    }
    $body = [byte[]]::new($packed)
    [Array]::Copy($bytes,$header,$body,0,$packed)
    return [pscustomobject]@{
        Method=[Text.Encoding]::ASCII.GetString($bytes,2,5)
        Packed=$packed
        Original=$original
        Body=$body
        BodyHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($body))
    }
}

function Read-Lh3Payload(
    [byte[]]$Body,
    [byte[]]$Expected,
    [int[]]$PositionRootFallback = @(),
    [int[]]$CharacterRootFallback = @(),
    [int]$RepeatedByte = -1
) {
    if ($RepeatedByte -ge 0) {
        if (!('Lh3ConstantPayload' -as [type])) {
            Add-Type -TypeDefinition @'
public static class Lh3ConstantPayload {
    public static bool Matches(byte[] data, int value) {
        if (value < 0 || value > 255) return false;
        foreach (byte item in data) if (item != value) return false;
        return true;
    }
}
'@
        }
        if (![Lh3ConstantPayload]::Matches($Expected,$RepeatedByte)) { throw '反復入力の前提が成立していません' }
    }
    $reader = @{ Bytes=$Body; Bit=0 }
    function Read-Bits([int]$Count) {
        $value = 0
        for ($i=0; $i -lt $Count; $i++) {
            if ($reader.Bit -ge $reader.Bytes.Length * 8) { throw 'LH3 ビット列が途中で終わっています' }
            $value = ($value -shl 1) -bor (($reader.Bytes[$reader.Bit -shr 3] -shr (7 - ($reader.Bit -band 7))) -band 1)
            $reader.Bit++
        }
        return $value
    }
    function Make-Codes([int[]]$Lengths,[int]$Root) {
        $codes = @{}
        $counts = [int[]]::new(17)
        $active = 0
        foreach ($length in $Lengths) {
            if ($length -gt 0) { $counts[$length]++; $active++ }
        }
        $next = [int[]]::new(17)
        for ($length=1; $length -le 16; $length++) {
            $next[$length] = ($next[$length - 1] + $counts[$length - 1]) -shl 1
        }
        for ($symbol=0; $symbol -lt $Lengths.Length; $symbol++) {
            $length = $Lengths[$symbol]
            if ($length) {
                $codes["$length/$($next[$length])"] = $symbol
                $next[$length]++
            }
        }
        return @{ Codes=$codes; Root=$Root; Active=$active }
    }
    function Read-Symbol($Tree) {
        if ($Tree.Root -ge 0) { return $Tree.Root }
        $code = 0
        for ($length=1; $length -le 16; $length++) {
            $code = ($code -shl 1) -bor (Read-Bits 1)
            $key = "$length/$code"
            if ($Tree.Codes.ContainsKey($key)) { return $Tree.Codes[$key] }
        }
        throw '不正な LH3 Huffman 符号です'
    }
    function New-FixedPositionLengths {
        $lengths = [int[]]::new(128)
        $thresholds = @(1,1,3,6,13,31,78)
        $threshold = 0
        $length = 2
        for ($symbol=0; $symbol -lt 128; $symbol++) {
            while ($threshold -lt $thresholds.Count -and $thresholds[$threshold] -eq $symbol) {
                $length++
                $threshold++
            }
            $lengths[$symbol] = $length
        }
        return $lengths
    }

    $dictionary = [byte[]]::new(8192)
    [Array]::Fill($dictionary,[byte]32)
    $produced = 0
    $blocks = 0
    $matches = 0
    $zeroCharacterTrees = 0
    $zeroPositionTrees = 0
    $singletonCharacterTrees = 0
    $singletonPositionTrees = 0
    $characterRoots = [Collections.Generic.List[int]]::new()
    $positionRoots = [Collections.Generic.List[int]]::new()
    $tokenStream = [IO.MemoryStream]::new()
    $tokenWriter = [IO.BinaryWriter]::new($tokenStream)

    while ($produced -lt $Expected.Length) {
        $blockSize = Read-Bits 16
        if (!$blockSize) { throw '空の LH3 ブロックです' }

        $cLengths = [int[]]::new(286)
        $cRoot = -1
        for ($symbol=0; $symbol -lt 286; $symbol++) {
            if (Read-Bits 1) { $cLengths[$symbol] = (Read-Bits 4) + 1 }
            if ($symbol -eq 2 -and $cLengths[0] -eq 1 -and $cLengths[1] -eq 1 -and $cLengths[2] -eq 1) {
                $cRoot = Read-Bits 9
                [Array]::Clear($cLengths)
                $singletonCharacterTrees++
                break
            }
        }
        $cActive = @($cLengths | Where-Object { $_ -gt 0 }).Count
        if (!$cActive -and $cRoot -lt 0) {
            if ($blocks -ge $CharacterRootFallback.Count -or $CharacterRootFallback[$blocks] -lt 0) {
                throw '原版 LH3 の全ゼロ文字木に補完 root がありません'
            }
            $cRoot = $CharacterRootFallback[$blocks]
            $zeroCharacterTrees++
        }
        $cTree = Make-Codes $cLengths $cRoot
        $characterRoots.Add($cRoot)

        $positionMode = Read-Bits 1
        $pRoot = -1
        if ($positionMode -eq 0) {
            $pLengths = New-FixedPositionLengths
        } else {
            $pLengths = [int[]]::new(128)
            for ($symbol=0; $symbol -lt 128; $symbol++) {
                $pLengths[$symbol] = Read-Bits 4
                if ($symbol -eq 2 -and $pLengths[0] -eq 1 -and $pLengths[1] -eq 1 -and $pLengths[2] -eq 1) {
                    $pRoot = Read-Bits 7
                    [Array]::Clear($pLengths)
                    $singletonPositionTrees++
                    break
                }
            }
            $pActive = @($pLengths | Where-Object { $_ -gt 0 }).Count
            if (!$pActive -and $pRoot -lt 0) {
                if ($blocks -ge $PositionRootFallback.Count -or $PositionRootFallback[$blocks] -lt 0) {
                    throw '原版 LH3 の全ゼロ位置木に補完 root がありません'
                }
                $pRoot = $PositionRootFallback[$blocks]
                $zeroPositionTrees++
            }
        }
        $pTree = Make-Codes $pLengths $pRoot
        $positionRoots.Add($pRoot)

        for ($token=0; $token -lt $blockSize; $token++) {
            if ($produced -ge $Expected.Length) { throw 'LH3 ブロックに余分なトークンがあります' }
            $code = Read-Symbol $cTree
            if ($code -eq 285) { $code += Read-Bits 8 }
            $tokenWriter.Write([uint16]$code)
            if ($code -lt 256) {
                $tokenWriter.Write([uint16]0xffff)
                $length = 1
                $value = $code
                $position = 0
            } else {
                $encodedPosition = ((Read-Symbol $pTree) -shl 6) + (Read-Bits 6)
                $tokenWriter.Write([uint16]$encodedPosition)
                $length = $code - 253
                $distance = $encodedPosition + 1
                $position = ($produced - $distance) -band 8191
                $matches++
            }
            if ($produced + $length -gt $Expected.Length) { throw 'LH3 トークンが元入力の終端を越えています' }
            if ($RepeatedByte -ge 0) {
                # 一定値なら既に検証済みの前方部分を参照するか、初期辞書の空白を参照する。
                if (($code -lt 256 -and $value -ne $RepeatedByte) -or
                    ($code -ge 256 -and $distance -gt $produced -and $RepeatedByte -ne 32)) {
                    throw "LH3 の反復入力トークンが不正です: offset=$produced"
                }
                $produced += $length
            } else {
                for ($i=0; $i -lt $length; $i++) {
                    if ($code -ge 256) { $value = $dictionary[($position + $i) -band 8191] }
                    if ($value -ne $Expected[$produced]) {
                        throw "LH3 本文が元入力と違います: offset=$produced, actual=$value, expected=$($Expected[$produced])"
                    }
                    $dictionary[$produced -band 8191] = $value
                    $produced++
                }
            }
        }
        $blocks++
    }

    $tokenWriter.Flush()
    $tokenBytes = $tokenStream.ToArray()
    $tokenHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($tokenBytes))
    $tokenWriter.Dispose()
    $tokenStream.Dispose()
    return [pscustomobject]@{
        Blocks=$blocks
        Matches=$matches
        Bits=$reader.Bit
        ZeroCharacterTrees=$zeroCharacterTrees
        ZeroPositionTrees=$zeroPositionTrees
        SingletonCharacterTrees=$singletonCharacterTrees
        SingletonPositionTrees=$singletonPositionTrees
        CharacterRoots=[int[]]$characterRoots.ToArray()
        PositionRoots=[int[]]$positionRoots.ToArray()
        TokenHash=$tokenHash
    }
}

$specifications = @(
    @{ Name='stored-small'; Pattern='repeat'; Size=17; Method='jm6'; Expected='-lh0-' },
    @{ Name='stored-random'; Pattern='random'; Size=8193; Method='jm6'; Expected='-lh0-' },
    @{ Name='jm5-below-boundary'; Pattern='repeat'; Size=8191; Method='jm5'; Expected='-lh2-' },
    @{ Name='repeat-jm6'; Pattern='repeat'; Size=8191; Method='jm6'; Expected='-lh3-'; Repair=$true; Root=0 },
    @{ Name='repeat-jm5-boundary'; Pattern='repeat'; Size=8192; Method='jm5'; Expected='-lh3-'; Repair=$true; Root=0 },
    @{ Name='block65-jm6'; Pattern='block65'; Size=8191; Method='jm6'; Expected='-lh3-'; Repair=$true; Root=1 },
    @{ Name='block65-jm5-boundary'; Pattern='block65'; Size=8192; Method='jm5'; Expected='-lh3-'; Repair=$true; Root=1 },
    @{ Name='dynamic-two-groups'; Pattern='two-groups'; Size=32768; Method='jm6'; Expected='-lh3-' },
    @{ Name='runs-singleton'; Pattern='runs'; Size=32768; Method='jm6'; Expected='-lh3-'; Repair=$true; Root=0 },
    @{ Name='dynamic-multiblock'; Pattern='paired4096'; Size=131072; Method='jm6'; Expected='-lh3-'; MultiBlock=$true },
    @{ Name='singleton-character-multiblock'; Pattern='repeat'; Size=15360002; Method='jm6'; Expected='-lh3-'; Repair=$true; Root=0; Blocks=2; CharacterRoot=285; MultiBlock=$true; RepeatedByte=65 },
    @{ Name='jm5-after-lh3'; Pattern='repeat'; Size=8191; Method='jm5'; Expected='-lh2-' }
)
if ($CaseNames.Count) {
    foreach ($name in $CaseNames) {
        if ($name -cnotin $specifications.Name) { throw "未知の LH3 試験ケースです: $name" }
    }
    $specifications = @($specifications | Where-Object { $_.Name -cin $CaseNames })
}
$time = [datetime]::new(2024,1,2,3,4,6,[DateTimeKind]::Utc)
$sets = @{}

foreach ($api in $CommandApis) {
    foreach ($side in 'oracle','candidate') {
        $dll = if ($side -eq 'oracle') { $Oracle } else { $Candidate }
        $profileRoot = Join-Path $Workspace "$api-$side"
        New-Item -ItemType Directory -Path $profileRoot | Out-Null
        $fixtures = [Collections.Generic.List[object]]::new()
        $commands = [Collections.Generic.List[string]]::new()
        foreach ($specification in $specifications) {
            $root = Join-Path $profileRoot $specification.Name
            New-Item -ItemType Directory -Path $root | Out-Null
            $data = [byte[]](New-TestData $specification.Pattern $specification.Size)
            $input = Join-Path $root 'a.bin'
            [IO.File]::WriteAllBytes($input,$data)
            [IO.File]::SetCreationTimeUtc($input,$time)
            [IO.File]::SetLastWriteTimeUtc($input,$time)
            [IO.File]::SetLastAccessTimeUtc($input,$time)
            $archive = Join-Path $root 'result.lzh'
            $commands.Add("a -+ -$($specification.Method) -h2 -n1 -gm1 -y1 `"$archive`" `"$($root.Replace('\','/'))/`" a.bin")
            $fixtures.Add([pscustomobject]@{
                Specification=$specification
                Input=$input
                Archive=$archive
                Data=$data
                InputHash=(Get-FileHash -LiteralPath $input -Algorithm SHA256).Hash
            })
        }
        $arguments = @('--registry','','--enum-sequence-probe',$dll,'w64','1041','1',$api)
        $rows = @(& $TestProgram @arguments @commands 2>&1 | ForEach-Object { "$_" })
        $results = @($rows -match '^result=')
        [IO.File]::WriteAllLines((Join-Path $profileRoot 'commands.txt'),[string[]]$rows,[Text.UTF8Encoding]::new($false))
        if ($LASTEXITCODE -ne 0 -or $results.Count -ne $fixtures.Count -or @($results -cne 'result=0').Count) {
            throw "LH3 の連続圧縮に失敗しました: $api/$side"
        }
        $sets["$api/$side"] = $fixtures
    }
}

$pairCount = 0
$repairCount = 0
$exactLh3Count = 0
$multiBlockCount = 0
$payloadChecks = 0
foreach ($api in $CommandApis) {
    for ($index=0; $index -lt $specifications.Count; $index++) {
        $oracleFixture = $sets["$api/oracle"][$index]
        $candidateFixture = $sets["$api/candidate"][$index]
        $specification = $specifications[$index]
        $oracleMember = Read-CompressedMember $oracleFixture.Archive $oracleFixture.Data
        $candidateMember = Read-CompressedMember $candidateFixture.Archive $candidateFixture.Data
        if ($oracleMember.Method -cne $specification.Expected -or $candidateMember.Method -cne $specification.Expected) {
            throw "LH3 の格納方式が違います: $api/$($specification.Name), oracle=$($oracleMember.Method), candidate=$($candidateMember.Method)"
        }

        $candidateArchiveHash = (Get-FileHash -LiteralPath $candidateFixture.Archive -Algorithm SHA256).Hash
        foreach ($readerName in 'oracle','candidate') {
            $reader = if ($readerName -eq 'oracle') { $Oracle } else { $Candidate }
            $rows = @(& $runner --timeout-seconds 120 $TestProgram --registry '' --legacy-payload-probe `
                $reader $candidateFixture.Archive $candidateFixture.Input 2>&1 | ForEach-Object { "$_" })
            $payloadExit = $LASTEXITCODE
            [IO.File]::WriteAllLines((Join-Path (Split-Path -Parent $candidateFixture.Archive) "payload-$readerName.txt"),[string[]]$rows)
            if ($payloadExit -ne 0 -or $rows.Count -ne 3 -or
                @($rows -notmatch ',payload=1,prefix=1,tail=1,guard=1$').Count) {
                throw "LH3 の安全書庫を相互展開できません: $api/$($specification.Name)/$readerName (exit $payloadExit)`n$($rows -join "`n")"
            }
            $payloadChecks += 3
        }
        if ((Get-FileHash -LiteralPath $candidateFixture.Archive -Algorithm SHA256).Hash -cne $candidateArchiveHash) {
            throw 'LH3 の相互展開で候補書庫が変更されました'
        }

        if ($specification.Expected -cne '-lh3-') {
            if ($oracleMember.Packed -ne $candidateMember.Packed -or $oracleMember.BodyHash -cne $candidateMember.BodyHash) {
                throw "LH3 前後のフォールバック本文が原版と違います: $api/$($specification.Name)"
            }
        } else {
            $repeatByte = if ($specification.ContainsKey('RepeatedByte')) { $specification.RepeatedByte } else { -1 }
            $candidateParsed = Read-Lh3Payload $candidateMember.Body $candidateFixture.Data -RepeatedByte $repeatByte
            $oracleParsed = Read-Lh3Payload $oracleMember.Body $oracleFixture.Data `
                $candidateParsed.PositionRoots $candidateParsed.CharacterRoots -RepeatedByte $repeatByte
            if ($candidateParsed.TokenHash -cne $oracleParsed.TokenHash -or
                $candidateParsed.Blocks -ne $oracleParsed.Blocks -or
                $candidateParsed.Matches -ne $oracleParsed.Matches) {
                throw "LH3 のトークン列が原版と違います: $api/$($specification.Name)"
            }
            if ($specification.Repair) {
                $expectedBlocks = if ($specification.Blocks) { $specification.Blocks } else { 1 }
                if ($candidateMember.BodyHash -ceq $oracleMember.BodyHash -or
                    $candidateMember.Packed -ge $oracleMember.Packed -or
                    $candidateParsed.Blocks -ne $expectedBlocks -or
                    $candidateParsed.SingletonPositionTrees -ne $expectedBlocks -or
                    $candidateParsed.ZeroPositionTrees -ne 0 -or
                    @($candidateParsed.PositionRoots | Where-Object { $_ -ne $specification.Root }).Count -ne 0 -or
                    $oracleParsed.ZeroPositionTrees -ne $expectedBlocks -or
                    $oracleParsed.SingletonPositionTrees -ne 0) {
                    throw "LH3 の単一位置木の安全修正が不正です: $api/$($specification.Name)"
                }
                if ($specification.ContainsKey('CharacterRoot') -and
                    ($candidateParsed.SingletonCharacterTrees -ne 1 -or $oracleParsed.ZeroCharacterTrees -ne 1 -or
                     $candidateParsed.CharacterRoots[1] -ne $specification.CharacterRoot -or
                     $candidateParsed.ZeroCharacterTrees -ne 0)) {
                    throw 'LH3 の単一文字木の安全修正が不正です'
                }
                $repairCount++
            } else {
                if ($candidateMember.Packed -ne $oracleMember.Packed -or
                    $candidateMember.BodyHash -cne $oracleMember.BodyHash -or
                    $candidateParsed.ZeroPositionTrees -ne 0 -or
                    $oracleParsed.ZeroPositionTrees -ne 0) {
                    throw "LH3 の動的木本文が原版と一致しません: $api/$($specification.Name)"
                }
                $exactLh3Count++
            }
            if ($specification.MultiBlock) {
                if ($candidateParsed.Blocks -lt 2) { throw 'LH3 の複数ブロック境界を通過していません' }
                $multiBlockCount++
            }
        }

        foreach ($fixture in $oracleFixture,$candidateFixture) {
            if ((Get-FileHash -LiteralPath $fixture.Input -Algorithm SHA256).Hash -cne $fixture.InputHash) {
                throw 'LH3 圧縮または検証で入力ファイルが変更されました'
            }
        }
        $pairCount++
    }
    Write-Host "LH3 compression: $api, $pairCount comparisons passed"
}

$expectedPairs = $CommandApis.Count * $specifications.Count
$expectedRepairs = $CommandApis.Count * @($specifications | Where-Object { $_.Repair }).Count
$expectedExact = $CommandApis.Count * @($specifications | Where-Object { $_.Expected -eq '-lh3-' -and !$_.Repair }).Count
$expectedMultiBlocks = $CommandApis.Count * @($specifications | Where-Object { $_.MultiBlock }).Count
if ($pairCount -ne $expectedPairs -or $repairCount -ne $expectedRepairs -or
    $exactLh3Count -ne $expectedExact -or $multiBlockCount -ne $expectedMultiBlocks) {
    throw 'LH3 の必要な境界・安全修正・動的木・複数ブロック条件が実行されていません'
}
foreach ($path in $hashes.Keys) {
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $hashes[$path]) {
        throw "LH3 検証中に実行ファイルが変更されました: $path"
    }
}
Write-Host "LH3 compression: $pairCount method/body/token pairs, $repairCount safe singleton-tree cases, $exactLh3Count exact dynamic-tree bodies, $multiBlockCount multiblock cases, and $payloadChecks cross-reader payload/guard records passed"
