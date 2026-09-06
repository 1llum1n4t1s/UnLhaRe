[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$scripts=@('test-command-short-header-state.ps1','test-compression-code-pages.ps1',
    'test-compression-update-progress.ps1','test-decode-progress-state.ps1',
    'test-header-crc-api-state.ps1','test-header-crc-command-state.ps1','test-compression-progress-cancel.ps1')
$count=0
foreach($name in $scripts){
    $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $name),[ref]$null,[ref]$errors)
    if($errors.Count){throw "構文エラー: $name"}
    # 各呼び出し元が実際に使う置換式を取り出す。試験用の別実装とは比較しない。
    $expressions=@($ast.FindAll({param($node)
        $node -is [Management.Automation.Language.BinaryExpressionAst] -and
        $node.Operator -eq [Management.Automation.Language.TokenKind]::Ireplace -and
        $node.Right -is [Management.Automation.Language.ArrayLiteralAst] -and
        $node.Right.Elements.Count -eq 2 -and
        $node.Right.Elements[1].Value -like ',metadata=undefined*,source='
    },$true))
    if($expressions.Count -ne 1){throw "DIRECTORY の置換式が一意ではありません: $name"}
    $expression=[scriptblock]::Create($expressions[0].Extent.Text)
    $replacement=$expressions[0].Right.Elements[1].Value
    $prefix='progress.entry=msg=1,state=5,legacy-file=undefined,legacy-write=undefined'
    $numbers=',file=1,compressed=2,write=3,attributes=4,crc=5,os=6,ratio=7,create=8,access=9,write-time=10'
    $suffix='name="added.txt",dest=path="",owner=1'
    foreach($mode in '',',source=added.txt','\",source=name=\"fake\"','\\,source=foo','\x81,source=foo'){
        $row=$prefix+$numbers+',mode="'+$mode+'",source='+$suffix
        $normalized=& $expression
        if($normalized -cne $prefix+$replacement+$suffix){throw "引用欄を区切りと誤認しました: $name / $mode"}
        $count++
    }
    # 本当の source / dest / owner の変更を消してはいけない。
    $baseline=$prefix+$replacement+$suffix
    foreach($changed in 'name="other.txt",dest=path="",owner=1',
                        'name="added.txt",dest=path="other",owner=1',
                        'name="added.txt",dest=path="",owner=0',
                        'name=",source=fake,mode=\"quoted\"",dest=path="",owner=1'){
        $row=$prefix+$numbers+',mode=",source=garbage",source='+$changed
        $normalized=& $expression
        if($normalized -ceq $baseline -or $normalized -cne $prefix+$replacement+$changed){throw "確定欄の差を隠しました: $name"}
        $count++
    }
    $row=$prefix+$numbers+',mode="unterminated,source='+$suffix
    if((& $expression) -cne $row){throw "壊れた引用欄を正規化しました: $name"}
    $count++
}
Write-Host "DIRECTORY normalization: $count quoted-field and difference-preservation checks passed"
