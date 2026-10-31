# 8-anchor inverse 先行有限契約

親PLAN SHA5974FC25B160262D91D0AC47D8BFCA28A0CF68A99AE70558C91FC93279D9E52D読了。以下は実装前固定、全native/compile未実行。旧reference/packed24/contract/memory/BWTと証拠は凍結。所有6filesだけ、親レビュー後compile1/native1。

## 正常・独立oracle

n1..23、plain n-1、recipe4（全0/全255/0と255交互/affine73i+19）の92cases。BWT各1、独立u16 sentinel suffix-sortのSA/BWT/primary全部を直接比較。reference/packed24/anchor各全plain入力一致。n<8の28casesは空metadataのみpacked24-fallback、n>=8の64casesは32B serialize/parseと全8SA対応512比較。全n%8=0..7を覆う。独立suffix-sortはtiny範囲だけのoracleでありSA-IS全域の証明ではない。

巨大3casesはn8388607/8388608/8388609、last=[1…1,0]を一caseずつ生成。reference結果を保持、old24全plain比較後drop、metadata生成wordsをdrop、candidate全plain比較。全expected0を全byte検査、metadata32B/生成と復元scratch容量n/result n-1/last capacityを記録。巨大forward BWT/別expected Vecなし。

## 拒否・復帰

旧11不正last/primary/sentinel/alphabet、cycle3/16/72の3、alphabet wrapper2/長さMAX_N+1 wrapper1をgeneration/decoder双方別counterで17件ずつ拒否。下記canonical追加を別欄にする。旧n1..8/3symbol/sentinel1の1793列を逐次再実行、旧reference/old24/generator/candidateの受理一致、accepted255/rejected1538、受理全plain一致。無効lastにも指定metadata（n<8空/n8 identity anchors）をdecoderへ渡し、generator拒否だけでdecoder検証を代用しない。

metadata専用拒否9件：正常n24の31B/33B/row=n/anchor0違い/重複/未使用rowへ1行ずれ/anchor1と2交換、n16の別cycle、n72最強反例。n<8への非empty canonical拒否1件を別追加。n72 last=[1×7,0,1×64],primary7,alphabet[0,1],q9,anchors=[7,0,1,2,3,4,5,6]は全anchorunique/各segment終端一致を別計算した上で拒否を要求。interleave検査の最初のglobalstepは固定せず、各lane load/write前globalstep>0のprimary検査を要求。generationもcycle16/72拒否。各metadata拒否後に正常復元＝10復帰。24bit pack両端×byte0/255の4roundtrip＋index2^24拒否1。

## 固定診断・資源

input一read/BWT1、metadata生成1（LF allocate/build/fullwalk/free/実32B serialize費用を別ns計時）。old24/candidate warm1各、9round AB/BA交互＝18timedcalls、毎回全plain直接比較。各timedcallはscratch確保/初期化/guard/walk/freeとcandidate parseを含み、比較/呼出元dropは外。全18rawns・overall/AB/BA中央値保存、quiet未確認/正式速度未claim。metadata CRC・完成wire/encode達成は未実装。

最大巨大reference phase 15n-2+4MiB=130023437B、candidate phase 8n-2+32+4MiB=71303206B。metadata生成wordsと候補wordsは同時保持しない。fixed BWT141598926Bは別phase源式、実WS/private各160MiBはWinAPI独立測定。source+PLAN300KiB/EXE1MiB/report256KiB/output8MiB/free5GiB、compile60/native120s、再測定/ASM/rawdisk/input/frame/plaincopy0。旧permutation report/EXE/source/readonlyをbefore-after-live pin。閉包parserを緩和しない。検証実行は親だけ、READYで6file停止返却。GOAL未達/active、Git/製品/x86/外部/delete/追加委任0。
