# 親側の独立有限再計算。nativeのHuffmanコードやparserを呼び出さない。
function Independent-Huffman257($hist){
 if(@($hist).Count -ne 257){throw 'Histogram extent'}
 $nodes=[Collections.Generic.List[object]]::new()
 $queue=[Collections.Generic.List[int]]::new()
 $leafIds=[int[]]::new(257);[Array]::Fill($leafIds,-1)
 $total=0L;$nonzero=0
 for($i=0;$i -lt 257;$i++){
  $v=[long]$hist[$i]
  if($v -lt 0 -or $v -gt 1708032 -or [double]$hist[$i] -ne $v){throw 'Histogram weight'}
  $total+=$v;if($total -gt 1708032){throw 'Histogram total'}
  if($v){$id=$nodes.Count;$leafIds[$i]=$id;$nodes.Add([pscustomobject]@{weight=$v;minimum=$i;parent=-1});$queue.Add($id);$nonzero++}
 }
 while($queue.Count -gt 1){
  # 最大257項目の独立ソート。符号木のコピーではなく優先順から再構築。
  $ordered=@($queue|Sort-Object @{Expression={$nodes[$_].weight}},@{Expression={$nodes[$_].minimum}},@{Expression={$_}})
  $a=[int]$ordered[0];$b=[int]$ordered[1]
  $null=$queue.Remove($a);$null=$queue.Remove($b)
  $id=$nodes.Count;$weight=$nodes[$a].weight+$nodes[$b].weight
  if($id -ge 513 -or $weight -gt 1708032){throw 'Huffman tree bound'}
  $nodes[$a].parent=$id;$nodes[$b].parent=$id
  $nodes.Add([pscustomobject]@{weight=$weight;minimum=[Math]::Min($nodes[$a].minimum,$nodes[$b].minimum);parent=-1});$queue.Add($id)
 }
 $lengths=[int[]]::new(257);$cost=0L;$max=0
 for($i=0;$i -lt 257;$i++){
  if($leafIds[$i] -lt 0){continue}
  $id=$leafIds[$i];$depth=0
  while($nodes[$id].parent -ge 0){$depth++;if($depth -gt 255){throw 'Huffman cycle/depth'};$id=$nodes[$id].parent}
  if($nonzero -eq 1){$depth=1}
  $lengths[$i]=$depth;$max=[Math]::Max($max,$depth);$cost+=[long]$hist[$i]*$depth
 }
 $kraft=0L
 if($max -le 15){foreach($depth in $lengths){if($depth){$kraft+=1L -shl (15-$depth)}}
  if(($nonzero -gt 1 -and $kraft -ne 32768) -or ($nonzero -eq 1 -and $kraft -ne 16384) -or ($nonzero -eq 0 -and $kraft -ne 0)){throw 'Kraft sum'}
 }
 [pscustomobject]@{hist_total=$total;nonzero=$nonzero;lengths=$lengths;max_length=$max;weighted_bits=$cost;valid=($nonzero -gt 0 -and $max -le 15);kraft_units=$kraft;tree_nodes=$nodes.Count}
}

function Independent-Canonical($lengths){
 if(@($lengths).Count -ne 257 -or $lengths[256] -ne 11){throw 'Fixed book extent/ESC'}
 $counts=[int[]]::new(12);$codes=[int[]]::new(257);$next=[int[]]::new(12);$kraft=0L
 for($i=0;$i -lt 257;$i++){
  $l=[int]$lengths[$i];if($l -lt 0 -or $l -gt 11 -or $l -ne $lengths[$i]){throw 'Fixed book length'}
  if($l){$counts[$l]++;$kraft+=1L -shl (11-$l)}
 }
 if($kraft -ne 2048){throw 'Fixed canonical Kraft'}
 $code=0
 for($bits=1;$bits -le 11;$bits++){$code=($code+$counts[$bits-1]) -shl 1;$next[$bits]=$code}
 for($i=0;$i -lt 257;$i++){if($lengths[$i]){$l=[int]$lengths[$i];$codes[$i]=$next[$l];$next[$l]++;if($codes[$i] -ge (1 -shl $l)){throw 'Canonical code bound'}}}
 $table=[byte[]]::new(129)
 for($i=0;$i -lt 257;$i++){$at=[int][Math]::Floor($i/2);if($i%2 -eq 0){$table[$at]=$lengths[$i] -shl 4}else{$table[$at]=$table[$at] -bor $lengths[$i]}}
 $prices=[int[]]::new(256)
 for($i=0;$i -lt 256;$i++){$prices[$i]=if($lengths[$i]){[int]$lengths[$i]}else{19}}
 [pscustomobject]@{codes=$codes;prices=$prices;table_hex=[Convert]::ToHexString($table);table_sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($table));known=$counts[1..11]|Measure-Object -Sum|Select-Object -ExpandProperty Sum;max_price=($prices|Measure-Object -Maximum).Maximum}
}

function Expected-Book($prior){
 $hist=[long[]]::new(257)
 for($i=0;$i -lt 256;$i++){$hist[$i]=$prior.screen.minor_census.histogram[$i]}
 $hist[256]=1;$h=Independent-Huffman257 $hist
 if($h.max_length -ne 11 -or $h.lengths[256] -ne 11 -or $h.weighted_bits -ne 14649){throw 'Fixed book independent histogram reconstruction'}
 $p=Join-Path $PSScriptRoot '../PAID_CODE_TREE_PLAN_20261005.md'
 if((Get-FileHash -LiteralPath $p).Hash -cne '8DD5902777BD58A56B224C154C1006B1A1EF90A8D766605313A923AA65EED803'){throw 'Fixed PLAN hash'}
 $plan=[IO.File]::ReadAllText($p)
 $found=[regex]::Match($plan,'(?s)```text\s+([0-9,]+)\s+```')
 if(!$found.Success){throw 'Fixed PLAN lengths'}
 $lengths=@($found.Groups[1].Value.Split(',')|ForEach-Object {[int]$_})
 if(($lengths|ConvertTo-Json -Compress) -cne ($h.lengths|ConvertTo-Json -Compress)){throw 'Fixed PLAN/rebuilt table'}
 $canonical=Independent-Canonical $lengths
 $baselineBits=[long]$prior.screen.minor_census.prefix_payload_bits-8*[long]$prior.screen.minor_census.minor_count+$h.weighted_bits-11
 $baselineBytes=134+[Math]::Ceiling($baselineBits/8)
 if($baselineBits -ne 19914 -or $baselineBytes -ne 2624){throw 'Independent repriced baseline expenses'}
 [pscustomobject]@{lengths=$lengths;canonical=$canonical;weighted_known_bits=$h.weighted_bits-11;baseline_payload_bits=$baselineBits;baseline_header_bytes=$baselineBytes}
}

