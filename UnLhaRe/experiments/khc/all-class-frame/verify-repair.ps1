$ErrorActionPreference='Stop'
$text=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'codec.rs'))
$new=@'
    let model_bound=raw.len()+s.front_capacity+s.dense_capacity+s.hist_capacity+s.fit_capacity+s.packet_capacity+s.parse_transient+SCRATCH_BOUND+4*1024*1024;
    gate(&mut s,model_bound)?;
'@
$old='    gate(&mut s,raw.len()+s.front_capacity+s.dense_capacity+s.hist_capacity+s.fit_capacity+s.packet_capacity+s.parse_transient+SCRATCH_BOUND+4*1024*1024)?;'
if([regex]::Matches($text,[regex]::Escape($new)).Count -ne 1){throw 'Model bound splice'}
$text=$text.Replace($new,$old)
$new=@'
    let encode_bound=raw.len()+s.front_capacity+s.dense_capacity+s.hist_capacity+s.fit_capacity+s.packet_capacity+s.forest_capacity+s.parse_transient+s.range_capacity_bound+HEADER+raw.len()+SCRATCH_BOUND+4*1024*1024;
    gate(&mut s,encode_bound)?;
'@
$old='    gate(&mut s,raw.len()+s.front_capacity+s.dense_capacity+s.hist_capacity+s.fit_capacity+s.packet_capacity+s.forest_capacity+s.parse_transient+s.range_capacity_bound+HEADER+raw.len()+SCRATCH_BOUND+4*1024*1024)?;'
if([regex]::Matches($text,[regex]::Escape($new)).Count -ne 1){throw 'Encoder bound splice'}
$text=$text.Replace($new,$old)
$new=@'
    let decode_bound=bytes.len()+s.forest_capacity+s.parse_transient+last.capacity()*2+s.inverse_capacity+s.output_capacity+SCRATCH_BOUND+1048576;
    gate(&mut s,decode_bound)?;let plain=inverse.plain;if crc32(&plain)!=get32(bytes,32)? as u32{return Err("plain CRC".into());}Ok((plain,s))
'@
$old='    gate(&mut s,bytes.len()+s.forest_capacity+s.parse_transient+last.capacity()*2+s.inverse_capacity+s.output_capacity+SCRATCH_BOUND+1048576)?;let plain=inverse.plain;if crc32(&plain)!=get32(bytes,32)? as u32{return Err("plain CRC".into());}Ok((plain,s))'
if([regex]::Matches($text,[regex]::Escape($new)).Count -ne 1){throw 'Decoder bound splice'}
$text=$text.Replace($new,$old)
$bytes=[Text.Encoding]::UTF8.GetBytes($text)
$sha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
if($bytes.Length -ne 14832 -or $sha -cne '7CD6623D7EBCA0D4F4423FFE0FA357F03D1A55D0C86BB0C8BFD59883104E7C69'){throw 'Exact initial codec reconstruction'}
[pscustomobject]@{status='readonly-passed';exact_reverse_splices=3;reconstructed_bytes=$bytes.Length;initial_sha256=$sha;disk_writes=0;compile_calls=0;native_calls=0}|ConvertTo-Json
