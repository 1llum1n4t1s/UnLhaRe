# private静的CDF header：一候補

bitは各fieldの下位bitから保存、bytes内もLSB-first。model-bit-lengthは別の4B framing見積り。header本体にtag version/magicは含めず、private診断だけに使用する。将来のcodec wireとは別契約。

1. rank global CDF（alphabet257）、length global CDF（alphabet256）。
2. rank group257個をsymbol順に、length group9個をexponent順に、それぞれ2bit tag。
3. tag0 inherit/global、tag1 own leaf（CDF1個）、tag2 inherit+4child、tag3 own+4child（group CDF1個）。split時child bucket0..3各1bit inherit/own、own時だけchild CDF。inherit childはそのgroupのbase（ownがあればown、なければglobal）。
4. CDFはused count9bit、sorted used symbol IDs9bitを全used分、最後以外freq15bitを順に保存。最後freqは32768-sum。freqはu32、cumulativeはalphabet+1個のu32、総和32768。
5. byte paddingはzero。bytesはceil(model bits/8)に一致し、parserは余剰byteや余剰declared bit、非zero paddingを拒否。split child4個すべてinheritは非canonicalとして拒否。

各groupの4候補をunconditional quantized loss+実field bitsで比較。child inherit/ownはbase CDFに対して比較し、tieはinherit。group tieはinherit、own leaf、inherit+child、own+childの順で、leafをsplitより優先する。空group/childはinheritのみ。

量子化：used個へ各1、残り32768-usedをcounts比でfloor比例配分、残余をHamilton最大剰余（symbol昇順tie）へ1ずつ。singletonはfreq32768で最後freqのみ暗黙保存。すべてchecked整数計算。

rank hist：(1+257+257×4)×257=330502 u32 cells。length hist：(1+9+9×4)×256=11776 cells。合計342278×4=1369112B。最大dense frequency+prefix工作領域は1332 CDF×概ねalphabet+alphabet+1のu32配列でhistと区別する。prefixのみの最大は((1286×258)+(46×257))×4=1374440B。

selected CDFのdecoder lookup最大見積りはselected count×32768×u16(2B)。全1332選択時は87293952B=83.25MiB。これは資源ゲートの合格ではなく、実allocation/初期化/速度も未実測。

選択後のscoreは同run sourceを再走査し、selected frequency[token]/cumulative[limit]を用いる。予算は実model bytes+ceil(truncated loss/8)+uniform escape bytes+285B framing+4B model-bit-length+2048B coder reserve。483599B以下でもcandidate資格だけで、実圧縮サイズ/roundtrip/速度を保証しない。
