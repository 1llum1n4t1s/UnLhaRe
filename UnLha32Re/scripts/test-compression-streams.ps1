[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Workspace
)
$ErrorActionPreference = 'Stop'
$TestProgram = (Resolve-Path -LiteralPath $TestProgram).Path
$Oracle = (Resolve-Path -LiteralPath $Oracle).Path
$Candidate = (Resolve-Path -LiteralPath $Candidate).Path
$Workspace = [IO.Path]::GetFullPath($Workspace)
New-Item -ItemType Directory -Path $Workspace -Force | Out-Null
Write-Host "Compression streams workspace: $Workspace"
$random = [Random]::new(81723)
$block = [byte[]]::new(8192)
$random.NextBytes($block)
$cases = @(
    @{ Name='alphabet'; Data=[Text.Encoding]::ASCII.GetBytes('abcdefghijklmnopqrstuvwxyz' * 200) },
    @{ Name='repeat-a'; Data=[Text.Encoding]::ASCII.GetBytes('a' * 5000) },
    @{ Name='repeat-ab'; Data=[Text.Encoding]::ASCII.GetBytes('ab' * 2500) },
    @{ Name='repeat-abc'; Data=[Text.Encoding]::ASCII.GetBytes('abc' * 1700) },
    @{ Name='unique-prefix'; Data=[Text.Encoding]::ASCII.GetBytes('Z' + ('abc' * 1700)) },
    @{ Name='reuse-position-zero'; Data=[Text.Encoding]::ASCII.GetBytes('abc' + ('X' * 5000) + 'abc') },
    @{ Name='block-8192'; Data=[byte[]]($block * 3) },
    @{ Name='block-4096'; Data=[byte[]]($block[0..4095] * 6) },
    @{ Name='slide-66000'; Data=[Text.Encoding]::ASCII.GetBytes('a' * 66000) },
    @{ Name='slide-600000'; Data=[Text.Encoding]::ASCII.GetBytes('abc' * 200000) }
)
$count = 0
$crossReads = 0
foreach ($case in $cases) { foreach ($switch in 'jm1','jm2','jm3','jm4','jmm12','jmm13','jmm14','jmm15','jmm16','jmm17','jmm18','jmm19') {
    $pair = @()
    foreach ($side in 'oracle','reimpl') {
        $root = Join-Path $Workspace "$($case.Name)/$switch/$side"
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $archive = Join-Path $root 'result.lzh'
        $inputPath = Join-Path $root 'a.bin'
        if (Test-Path -LiteralPath $archive) { throw "生成先が既に存在します: $archive" }
        [IO.File]::WriteAllBytes($inputPath,$case.Data)
        $time = [datetime]::new(2024,1,2,3,4,6,[DateTimeKind]::Utc)
        [IO.File]::SetCreationTimeUtc($inputPath,$time)
        [IO.File]::SetLastWriteTimeUtc($inputPath,$time)
        [IO.File]::SetLastAccessTimeUtc($inputPath,$time)
        $dll = if ($side -eq 'oracle') { $Oracle } else { $Candidate }
        $rows = @(& $TestProgram --registry '' --command-probe-a $dll "a -h2 -$switch -+ -gm1 -n1 -y1 `"$archive`" `"$root\`" a.bin" A)
        if ($LASTEXITCODE -ne 0 -or $rows -notcontains 'result=0') { throw "圧縮できません: $($case.Name)/$switch/$side" }
        $bytes = [IO.File]::ReadAllBytes($archive)
        if ($bytes[20] -ne 2) { throw 'level 2 ではありません。' }
        $headerSize = [BitConverter]::ToUInt16($bytes,0)
        $packedSize = [BitConverter]::ToUInt32($bytes,7)
        $originalSize = [BitConverter]::ToUInt32($bytes,11)
        if ($originalSize -ne $case.Data.Length) { throw '元サイズが一致しません。' }
        $method = [Text.Encoding]::ASCII.GetString($bytes,2,5)
        $pair += [pscustomobject]@{ Method=$method; Packed=$packedSize; Body=[Convert]::ToBase64String($bytes,$headerSize,$packedSize) }
        foreach ($reader in 'oracle','reimpl') {
            $readerDll = if ($reader -eq 'oracle') { $Oracle } else { $Candidate }
            $destination = Join-Path $root "extract-$reader"
            New-Item -ItemType Directory -Path $destination | Out-Null
            $rows = @(& $TestProgram --registry '' --command-probe-a $readerDll "e -+ -gm1 -y1 `"$archive`" `"$destination\`" a.bin" A)
            $extracted = Join-Path $destination 'a.bin'
            if ($LASTEXITCODE -ne 0 -or $rows -notcontains 'result=0' -or -not (Test-Path -LiteralPath $extracted) -or
                [Convert]::ToBase64String([IO.File]::ReadAllBytes($extracted)) -cne [Convert]::ToBase64String($case.Data)) {
                throw "相互展開の全バイトが一致しません: $($case.Name)/$switch/$side/$reader"
            }
            $crossReads++
        }
    }
    $equal = $pair[0].Method -ceq $pair[1].Method -and $pair[0].Body -ceq $pair[1].Body
    if (-not $equal) {
        throw "圧縮本体が一致しません: $($case.Name)/$switch, original=$($pair[0].Method)/$($pair[0].Packed), candidate=$($pair[1].Method)/$($pair[1].Packed)"
    }
    $count++
}
    Write-Host "Compression streams: $($case.Name), $count exact comparisons passed"
}
Write-Host "Compression streams: $count exact lh1/lh5/lh6/lh7/lhx bodies and $crossReads original/candidate full-byte cross extractions passed"
