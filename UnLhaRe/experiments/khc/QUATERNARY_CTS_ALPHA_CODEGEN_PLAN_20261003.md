# CTS alpha共通係数: 小容量の生成コード診断計画

## 問い・境界

PERF-ALPHAはupdate_kernelの各段が同じafterからalpha/retainedを作る候補。旧入口guard後のafter∈[1,CAP]なら分母非零、1<=alpha<=Q/2、retained>=0で係数計算のErrは到達不能。ただしcompilerが既に共通化している可能性がある。実装候補や速度改善と断定する前に、凍結旧primitiveをそのまま参照する小さなlibrary harnessのassemblyを確認する。

凍結q32 SHA5AE361CF9544AA75A86FECD852DBBCE6DA7EDF08AB169690B3C8A69973BEEED7、compiler SHACA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BCを使う。独立libraryのcodegenは現benchmark EXE全体の最終配置・inliningと同一とは限らず、実際のhot-loop時間や全入力の削減回数を証明するものではない。現depth5基点、formal gate、旧pool/旧Math、既存source/証拠は変更しない。

親だけが新alpha-codegen/のprobe.rs、verify-codegen.ps1、本計画と結果を所有する。rustc --emit=asm compile1回、候補CLI0、benchmark0、旧EXE実行0。製品/API/wire/version/Git/x86/shared cache/外部書込みは対象外。新Math/QCANCELを混ぜない。

## コードより先の失敗条件

1. q32 importを複製・改変したり、新数値bodyをharnessへ入れると問いが変わる。private moduleを旧sourceのpathで参照し、public wrapper2件は旧関数への直接callだけとする。
2. compiler/source/Math結果が既存証拠と違う場合は実行しない。旧report130 before/after/liveの全identityと新6件を前後照合する。UTF-8 JSON時刻はDateKind StringとUTCticksで比較する。
3. 既存root、reparse/リンク、混在、空き5GiB+1MiB不足、予算超過で停止。fresh build/khc-quaternary-cts-alpha-codegen-20261003を使い、assembly512KiB/report256KiB、全体1MiBまで。binary/rlib/object/PDB/input/frame/plain/traceを生成しない。前後disk-budgetを実行する。失敗時のstdout/stderr各64KiBと前後identityを収めるためreportを256KiB予約する。
4. compileはtimeout60秒、stdout/stderr各64KiB、失敗時はkill/disposeと記録保存。compileを好都合な結果へ再試行しない。capture制限はchildの出力監視でありassemblyのOS強制quotaではない。
5. 型・syntax・compileの失敗を隠さない。PS parser/nonExecuteを先に確認し、Executeは一度だけ。assembly未生成、空、上限超過、予定外ファイルがあれば成功扱いにしない。
6. mangled symbolの文字一致やdiv件数だけでhoistを断定しない。update wrapper・loop・call先posteriorを実際に読み、ループ入口/戻り辺と除算の位置を結び付ける。見えなければ証拠不足。
7. 生成コードだけでframe一致、速度、CPU、holdout、4native、製品統合を達成したとは言わない。depth0・複合不正入力・拒否順・独立旧oracleを含むE2Eは候補実装時に別計画で用意する。

## 識別・保持

旧Math report130に新計画/probe/runner/Math-result/report/EXEを加え136unique identitiesを前後保存。Math結果SHA BD18E259719C3F33B8B0857D56B135195C53F14DC88C53D7E57A325A4EDC2EE6、reportSHA0E252310BB8BE3415828258F190097D31CBD380A92A9CE9612C696E265E2D998、EXESHA60089C9B6241950CA9B29A1021AE85624C0BF1BD7C0F226F566CBD82033A960Dを固定する。大きな旧identity配列を再帰複製せず、今回の136件だけを保持する。

終了時に新rootの2file合計、source不変、所有child終了を確認する。小さなassemblyは生成コードの再現証拠として保持し、用途済み一時物だけ削除する。本計画はPerformance/Hardening/Testerの局所診断で、Modernizer/Normalizer/Cleanerは既存方式と凍結基点を保持、Asyncはchild解放のみ、Startup/Intelは非該当。
