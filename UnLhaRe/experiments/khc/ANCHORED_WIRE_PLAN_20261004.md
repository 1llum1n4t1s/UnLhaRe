# CRC付き8-anchor private wire：先行計画

前turnはSA採取のcompile/native/readonlyまで完了したprogress。今回は研究用全frameへ接続する。正式GOAL size<=483599B、CLI encode<574.5624ms/decode<47.3884ms、quiet<=15%、warm1+9、holdout/API/4nativeは変更しない。サイズだけ通過しても総合達成としない。約2秒payloadを解決したとは呼ばない。

## 所有と範囲・基礎検証

親はPLAN/readonly/RESULT/決定台帳。workerは新 `anchored-wire/FAILURE_PLAN.md`、`codec.rs`、`e2e.rs`、`anchor_scope.rs`、`probe.rs`、`run-native.ps1` の6filesのみ。failure-first/apply_patchのみ。old source/全旧証拠/製品dirty20files/依存/Git/version/x86/外部/削除は変更なし。READY/全編集停止/SHA回収・親全文確認前はcompile/native0。単一compile、native3（old-self/new-self/fixed-pair）を親が一回だけ実行。

基礎readonly：hard-cut-model-lazy/verify-readonly.ps1 exit0/149identity/raw2、anchored-sa-generation/verify-artifacts.ps1 exit0/59identity/raw1。旧frame478856B、新SAmetadata32Bは既に全文一致・全plain復元済みだがCRC付き新frameへ未接続。原モデルlazy_model.rs/adapter/CTS/pool/mathとe2e34fixture、原SA-ISと新SA採取/anchored decoderを直接凍結参照する。entropy-LUTやexp-scaleを重ねず、今回codecだけの差を切り分ける。

opop限定観点は親が全調査：Performanceはpacked24/8-chain逆変換とSA採取の全frame接続、Hardening/TesterはCRC保護と不正metadata・fallbackのE2E、Normalizerは原serialize/parseと共通モデル直接参照、Cleanerは置換された旧inverse実体を新codecに残さず全文置換ledgerを保持、Modernizerは固定runtime/依存変更不要、Asyncは両frame/復元plainの寿命とpin finally、Intelはローカルで決着し非該当、Startupは研究EXEで製品配布不変・非該当。

## 新private layoutと変更境界

旧hard-cut-model-lazy/codec.rsからallowlist変更だけで新codecを導出。モデル・数値・token grammar・payload encoding/decoding・原CRCは変えない。旧inverse_BWT本体は新codecから除去し、凍結anchored::inverse(...metadata).plainへ置換。新BWTは凍結anchored-sa-generation/bwt.rsを直接参照。旧scopeは原hard-cut-model-lazy/float_scope.rsを直接使う。新scope/probeはprivate型接続だけ。

MAGICは新8bytes `KHQCHA01`、旧 `KHQCHC01` を受理せずprivate旧形式との互換を主張しない。既存40B fields/depthとpacked alphabetの後にn=input.len()+1>=8なら32B anchor LEを追加し、それ未満は0B。header_crcは従来と同じ `[0..32] + [36..header_len]` を検査するので追加anchorも保護する。payloadそのものは旧と全byte一致。MAX_FRAME=MAX_PAYLOAD+317。decodeは40B最短guard→depth/既存fields→declared nによるanchor_len0/32→header_len minus payloadと73+anchor_len..285+anchor_lenのchecked bounds→CRC→packed alphabet/anchor解析→payload CRC→payload decode→8-chain復元/全plainCRCの順。CRC計算前やparse前のslice boundsを守る。anchor_lenはframe自由fieldではなくdeclared nから正準に決める。

固定期待：旧header285/payload478571/frame478856、新header317/payload478571/frame478888B。magic/headerCRC以外の共通fields/packed alphabet全文/全payload直接比較。各側encode/decode typedProof14一致、cross Debug14全字段一致（異なる型のtypedEqとは呼ばない）。statsはmagic/frame/header/headerCRCと新anchorのfieldsだけ差を許し、全残りfieldsを直接比較。固定CDF entropy bits/CRC/grammar/branches/classesを保持する。

## 先行有限E2E・failure契約

原正常14の全input→frame→plain→再encode全frame、short-header4を維持し、変換n7/8の境界を追加。新formatに必要なframe forge/header修復だけ更新。原malformed34は同じ原因を厳密に拒否する。旧inverseからpacked24-fallbackへ変わるLF cycle reason等の差があれば、名前/旧新reason/根拠を先にfailureplanとledgerに明記し、不定の任意Errへ緩和しない。

新named失敗は旧hardcut magic、CRC未修復anchor bitflip、CRC修復済みrow>=n/anchor0違い/重複/segment endpoint mismatch、n72/primary7/last[1×7,0,1×64]/anchors[7,0,1,2,3,4,5,6]全終端一致でもprimary早期再訪、metadata不足/余剰とfallbackに余分metadataを加えたframe。invalid frameのforgeは必要な場所まで到達できる正準alphabetとunique anchorを先に与え、parseの別guardで予定外に弾かれて当該検査を実行しない偽のcoverageを避ける。各named拒否後は同process正常tiny復元を確認。全件数をコード前FAILUREへ固定、親最終preflightで静的件数とsource/PINを凍結。

新selfcheck内にはoldフォーマットdecoderへ新frameを渡す旧MAGIC拒否を最低1件。逆方向oldframeもnewMAGIC拒否。fallback n<8はempty metadata・header既存幅、n>=8は32Bを全正常frameで確認し、metadataをCRCで包んだだけで意味検証済みとは呼ばない。全plain比較をCRC/hashへ置き換えない。OOM/製品CLI no-output/書込みsync faultは今回未検証、RAM decode拒否はplainを返さずディスク出力0。

## 単一fixed比較と資源

一read fixed input2811006B SHA18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76。old/new encode2、old/new restore2、固定reencode0。各typedProof14/全stats/全plain直接比較＋cross共通header/alphabet/payload全byte比較。旧plainは新restore前にdrop、BWT phaseではplain出力を保持しない。single pair encode/decode nsは内部screen/quiet未確認、warm9/fullCLI/formal speed/adoptionを主張しない。

Rust source+PLAN+FAILURE<=300KiB、source closure<=28/edges<=36（実件数をpreflightで固定）、EXE<=1MiB、report<=256KiB、stdout<=64KiB/stderr<=16KiB、outroot8MiB/minfree5GiB。unused `build/khc-anchored-wire-20261004` のEXE＋report2filesのみ。全model/input/frame/plain/rawtraceはRAMで扱い新Cargo/ASM/PDB/生コピーなし。BWT source phase141598926Bに旧frame最大1048861B＋small audit4096Bを加えた142651883B、160MiB以内。model/encode/inverse/dataのphaseはactual capacitiesとsource式を報告し、実WS/private両peak<=160MiBを各native別確認。guard事前/事後/report後。

rustcSHA CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC、pwshSHA362A356CE7F0940EC74F73A8FC2C990A2CC24A38A11C90BBD8ECA947110AD139。edition2024/wire_audit/opt3/thin/CGU1/unwind/overflowyes/debug0/DEBUG:NONE、compile60/native各120s、compile1/native3。bounded AST helperを固定SHAから抽出し旧entrypoint未実行。prices末尾cfg(test)の原SHA限定graph-only除外を既存normal runnerと同じexact allowlistで再利用し、compilerは原pricesを読みparser一般緩和なし。

旧normal report62B93E3FF942CEB13ECD6572DAD6CDBBE4DD45F88B72512E9348BBA4812BBEF3/EXE93A68018BC95F2731F3B42BAB8E943F299FE091616D6E0CF6D10001E7EF20D51、旧SA reportA4C1128B0092FC89D20D419AF87059ADCF607F76E989262396E41B5F0AD8DAAE/EXE27050B585AD48BE4CB53B4AB7B6504172091EE8A28FE9D973AD5D6B201D88657、全旧before/after/live・tools/input/PLAN/新sourceをpinし不変を確認。既存証拠を上書き/削除しない。失敗時は原因と証拠を保持し、同条件盲再実行をしない。親readonly追加compile/native0と結果保存後も全GOAL gateは維持して継続する。
