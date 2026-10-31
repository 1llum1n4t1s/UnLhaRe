# 親側の独立有限再計算。nativeのHuffmanコードやparserを呼び出さない。
function Independent-Huffman($hist){
 if(@($hist).Count -ne 256){throw 'Histogram extent'}
 $nodes=[Collections.Generic.List[object]]::new()
 $queue=[Collections.Generic.List[int]]::new()
 $leafIds=[int[]]::new(256);[Array]::Fill($leafIds,-1)
 $total=0L;$nonzero=0
 for($i=0;$i -lt 256;$i++){
  $v=[long]$hist[$i]
  if($v -lt 0 -or $v -gt 1708032 -or [double]$hist[$i] -ne $v){throw 'Histogram weight'}
  $total+=$v;if($total -gt 1708032){throw 'Histogram total'}
  if($v){$id=$nodes.Count;$leafIds[$i]=$id;$nodes.Add([pscustomobject]@{weight=$v;minimum=$i;parent=-1});$queue.Add($id);$nonzero++}
 }
 while($queue.Count -gt 1){
  # 最大256項目の独立ソート。符号木のコピーではなく優先順から再構築。
  $ordered=@($queue|Sort-Object @{Expression={$nodes[$_].weight}},@{Expression={$nodes[$_].minimum}},@{Expression={$_}})
  $a=[int]$ordered[0];$b=[int]$ordered[1]
  $null=$queue.Remove($a);$null=$queue.Remove($b)
  $id=$nodes.Count;$weight=$nodes[$a].weight+$nodes[$b].weight
  if($id -ge 511 -or $weight -gt 1708032){throw 'Huffman tree bound'}
  $nodes[$a].parent=$id;$nodes[$b].parent=$id
  $nodes.Add([pscustomobject]@{weight=$weight;minimum=[Math]::Min($nodes[$a].minimum,$nodes[$b].minimum);parent=-1});$queue.Add($id)
 }
 $lengths=[int[]]::new(256);$cost=0L;$max=0
 for($i=0;$i -lt 256;$i++){
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

function Independent-Fees([long]$bits,[long]$compact,$hist){
 if($bits -lt 0 -or $compact -lt 0 -or $compact -gt $bits){throw 'Metadata extent'}
 $h=Independent-Huffman $hist
 $retag=$bits-$compact;$raw=5+[long][Math]::Ceiling($retag/8.0)
 $payload=$retag-8*$h.hist_total+$h.weighted_bits
 if($payload -lt 0){throw 'Metadata payload arithmetic'}
 $coded=133+[long][Math]::Ceiling($payload/8.0)
 $selected=if($h.valid){[Math]::Min($raw,$coded)}else{$raw}
 [pscustomobject]@{huffman=$h;retagged_bits=$retag;raw_metadata_bytes=$raw;huffman_payload_bits=$payload;huffman_metadata_bytes=$coded;estimated_metadata_bytes=$selected}
}
