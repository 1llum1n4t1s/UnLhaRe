# 正規化priorのfull codec: 実行前契約

前段PROGRESS。新整数CDF/scaleは4条件で独立oracleへ一致、report `build/khc-direct-token-prior-model-20261002/report.json` SHA `BD8090CE5C601F2BAC4C8E297E8C84FFD5D8FAE665B720ED1043580E676EFA2D`。scale13170475照合・補正1証人116522、393216更新・424319 interval・455422 select・1118306 count比較、root/local rescale45/21、fingerprint63d2b815cfcd6e6e。親も実source/APIとnaive配列/通常除算/linear searchを確認した。まだfull frameや性能改善の証拠ではない。

## 新candidateと想定する失敗

- `DIRECT_TOKEN_PRIOR_CONTRACT_20261002.md` SHA `FB8373882F90882F8BAB50D3B9ECBC390181A2E769F3720DDDF001C0618752FB` のP256/CDFを、前fullcodecのgrammar/header/CRC/no-clobber/BWT/packed/inverse BWTへ接続する。新magic `KHNPR001`、別研究format。rank/length文脈、escape、boundsは変えない。old/new magic相互拒否、旧KHNTOK01を新decoderが拒否することも確認する。旧source/proof/計測済み候補は編集しない。
- CDF `cdf_model.rs` SHA `C046AF706803795762A6D2B3522A9D8747B08EDDA511DF0D576724F30BFD6E5C`、scale `prior_math.rs` SHA `138A83296052C562E35493D51943B744D450818D99FA2C09D5D769B08EB3B928` を再利用。rangeは旧 `direct-token/multi_range.rs` SHA `CAEEA3C1CD6BCD26A45BFEDC4EAF1A825C4A6860E0958E2FEA1C9EAA403F8129` でdomain<=81920を維持。normalized total<=66045、payload8*n+32、Run12byte、input8MiB、reserved frameの上限は前full契約と同じ。
- scale証明の厳密な境界補足: 元契約の `error<n/2^32` はn>0の場合。n=0はerror=0を直接確認する。全domainでerror<1、guessは正解か1小さい、補正とinteger remainder certificateでexact floorに一致する。prefix0を含む数値実測も成功している。sourceや元immutable契約は変更しない。
- full7入力は前fullと同じexactfixture生成seed/長さ/固定all.group SHAを使う。4compiler opt2/3×overflow yes/noで28 encode/decode全byte+21frame実byte比較。独立literal normalized intervalsによるzeros255/256/257、23拒否+validempty、CRC/grammar/primary/LF/fields/metadata/terminal等の意図stderr、missing/args/operation/no-clobber保持を確認する。独立forgeはmodel/codec encoderを使わない。
- literal初期CDFはrank alphabet257でC1=1/C2=3、length alphabet256でC(k)=2*k。初回 rank0 active2=(0,1,3)、rank1=(1,2,3)、length escape=(510,2,512)。初回 rank0更新後に別symbolのactive1は(0,2,2)。nonzero length token更新後の別symbol/remaining1は(0,1,1)、token0更新後は(0,2,2)。一つずつ累積全体のfloorとcausal countsから導き、old tupleを単純流用しない。
- 完全frame<=483599byteのみsize合格。前frame575791byteとの改善は実byte長で報告し、まだgapがあれば不採用。正式encode median574.5624ms未満/CPU15%/warmup1+9/同境界decode等を緩和しない。size不合格で正式benchmarkを起動しない。今回のelapsedは診断のみで性能勝利ではない。

## 容量・証拠・所有

fresh root `build/khc-direct-token-prior-full-20261002`、64MiB/通常3MiB/最悪50MiB（固定frame2個最大44.98MiB+restore2.81MiB+小fixture/EXE/report）。4codec EXE+forge+7reference frame+bounded reportだけ残す。入力/復元/condition/forgeは実比較後にexactowned/non-reparse/child終了/stream閉鎖を確認して逐次削除し、transient_path/SHA/bytes/比較byte数/削除のledgerを残す。固定inputをコピーせず、source/PDB/Cargo/cache/rawtraceを増やさない。

親は `direct-token-prior/codec.rs` と本契約・結果、workerは同dir `verify-full.ps1`/`frame_cases.rs`/`FULL_FAILURE_PLAN.md` と指定full rootを所有。primitive workerの3ファイルとprimitive rootに触れない。parentfreeze/hash通知後に一度run。actual import/contract/guard/primitive reports/compiler/runtime/固定input/旧EXE/旧frameを実行前後pin/read lockする。child120秒/各stdout stderr65536/report512KiB、disk-budget前後。初回入口のpath typoを繰り返さず、schema/PSparser/実在pathを実行前に照合する。

生成・validation以外のshell source書込みは禁止しapply_patchを使う。失敗root上書き/自動同条件再試行なし。fixture削除だけが範囲で、旧証拠/ユーザーinput/共有cache/x86を削除しない。Git stage/commit/push、version/公開/外部書込み、追加委任なし。

全目的はサイズ・encode/decode速度・holdout/カテゴリ・4native・製品/API安全性統合を含む。primitive/full E2Eや前候補相対改善だけへ縮めず、7-Zip総合超えの証拠が揃うまでgoal activeを維持する。
