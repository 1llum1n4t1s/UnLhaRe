param([string]$Destination = (Join-Path $PSScriptRoot '../../build/khc-corpus'))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = [IO.Path]::GetFullPath($Destination)
if (Test-Path -LiteralPath $root) { throw 'Destination must be new; use the existing immutable corpus or choose a new directory.' }
$null = New-Item -ItemType Directory -Path $root

# 公式の配布をローカル評価だけに使用。内容や利用条件を第三者向けに再配布しない。
$corpora = @(
    @{
        name = 'canterbury-development'
        role = 'development'
        url = 'https://corpus.canterbury.ac.nz/resources/cantrbry.zip'
        members = @{
            'alice29.txt'=152089; 'asyoulik.txt'=125179; 'cp.html'=24603; 'fields.c'=11150
            'grammar.lsp'=3721; 'kennedy.xls'=1029744; 'lcet10.txt'=426754; 'plrabn12.txt'=481861
            'ptt5'=513216; 'sum'=38240; 'xargs.1'=4227
        }
    },
    @{
        name = 'silesia-holdout'
        role = 'holdout-not-yet-measured'
        url = 'https://sun.aei.polsl.pl/~sdeor/corpus/silesia.zip'
        members = @{
            'dickens'=10192446; 'mozilla'=51220480; 'mr'=9970564; 'nci'=33553445
            'ooffice'=6152192; 'osdb'=10085684; 'reymont'=6627202; 'samba'=21606400
            'sao'=7251944; 'webster'=41458703; 'xml'=5345280; 'x-ray'=8474240
        }
    }
)
$manifests = @()
foreach ($corpus in $corpora) {
    $zipPath = Join-Path $root ($corpus.name + '.zip')
    Invoke-WebRequest -Uri $corpus.url -OutFile $zipPath -TimeoutSec 120
    $output = Join-Path $root $corpus.name
    $zip = [IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        # ファイル名とサイズを一次資料の一覧へ照合してから、flatな専用出力先へ展開する。
        if ($zip.Entries.Count -ne $corpus.members.Count) { throw 'Unexpected corpus entry count.' }
        $seen = @{}
        foreach ($entry in $zip.Entries) {
            if (-not $corpus.members.ContainsKey($entry.FullName) -or $seen.ContainsKey($entry.FullName)) { throw 'Unexpected or duplicate corpus member.' }
            if ($entry.Length -ne $corpus.members[$entry.FullName]) { throw 'Unexpected corpus member size.' }
            $seen[$entry.FullName] = $true
        }
        $null = New-Item -ItemType Directory -Path $output
        foreach ($entry in $zip.Entries) {
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, (Join-Path $output $entry.FullName), $false)
        }
    }
    finally { $zip.Dispose() }
    $files = @(Get-ChildItem -LiteralPath $output -File | Sort-Object Name | ForEach-Object {
        [pscustomobject]@{name=$_.Name; bytes=$_.Length; sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}
    })
    $manifests += [pscustomobject]@{
        name = $corpus.name
        role = $corpus.role
        source = $corpus.url
        archive_sha256 = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
        retrieved_utc = [DateTime]::UtcNow.ToString('o')
        files = $files
    }
    Write-Host "$($corpus.name): $($files.Count) inputs fixed; role=$($corpus.role)"
}
$manifests | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $root 'manifest.json') -Encoding utf8
