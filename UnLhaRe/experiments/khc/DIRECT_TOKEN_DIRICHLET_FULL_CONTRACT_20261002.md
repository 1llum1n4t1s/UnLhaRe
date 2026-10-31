# 高精度Dirichlet full codec: 実行前契約

数値検証は現在進行中。primitive4条件oracle成功と最終report SHAを親が確認・通知するまで、このfullのcompile/runは開始しない。数値結果を成功扱いした契約ではない。

## 固定candidateと失敗検証

DIRECT_TOKEN_DIRICHLET_CONTRACT_20261002.md SHA B9E3D754F2EF288B7A8C1A6DECF668DE71A2BBE14150EE5C693EDC3508616E5E、API51D98DCF5E76ECA6469DBEFEFCE62A18378A158D41D4B595D42C797F554F0D33のQ32768/lambda64を接続する。magic KHNDR001、新研究format。rank/length contexts、escape、Run12byte、packed/header/CRC/input8MiB/payload8*n+32/no-clobber/BWT/inverseは凍結旧grammarのまま。唯一の実行方式変更はmodel.prepareをquery群に共有すること。
codec SHA AC7541A7657F9CE9E56FEC06EFA07ADA00410AF2EBFA5FF966D64AA5DF9A4787。
cdf SHA D766225B2EE9DB5DA2F303ED65101E7F0A012A0067CED1F3F7CF4D66385A6020。
math SHA7296E6ADFFB2EE66F75F90FD35C2385D6FF224FE56B58C9B9A4C12345B48F398。
range旧CAEEA3C1CD6BCD26A45BFEDC4EAF1A825C4A6860E0958E2FEA1C9EAA403F8129。
新total<=33025、旧domain81920内、最悪normalizeの上限は旧8*n+32以内。

7入力は前fullと同じseed/長さ/固定all.group（2811006byte SHA18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76）。
opt2/3×overflow yes/no4条件で28encode/28decode全byte一致、21frame実byte比較。
独立forgeは通常整数除算・別のcountsモデル/手組みtiny metadataからCDFを計算し、候補のmodel/codec encodeを参照しない（range primitive使用可）。
zeros255/256/257の外部constructed frameと23拒否+validempty、CRC/grammar/primary/LF/fields/metadata/prefix/gap/trailing/terminal/no-clobber/missing/args/operationを確認する。以前のP256 tupleを流用せず、initial global/local countsと各causal updateから累積floorを独立計算する。旧balanced formatとの相互magic拒否、旧KHNPR001を新decoderが拒否することも確認する。旧codecは既存出荷EXEのmagic拒否呼び出しだけであり、過去terminal性能候補の再測定ではない。

完全frame<=483599byteだけをsize成功とする。前normalized610222byte、旧direct575791byteとの実byte差を報告。サイズ不合格なら正式benchmarkを開始せず不採用判定。正式encode median574.5624ms未満/CPU15%/warmup1+9/同境界decodeを緩和しない。E2E elapsedは診断だけであり速度勝利と扱わない。

## 容量・所有・証拠

fresh build/khc-direct-token-dirichlet-full-20261002、64MiB予算/通常3MiB/最悪50MiB（固定frame2個最大44.98MiB+restore2.81MiB+小fixture/EXE/report）。
4codec EXE+forge+7referenceframes+JSON512KiBのみ保持。入力/restore/condition/forgeは実byte比較後にexactowned/non-reparse/child終了/stream閉鎖を確認し逐次Remove-Item -LiteralPath。transient_path/SHA/bytes/比較bytes/削除をledgerに残し、固定inputを複製しない。証拠・旧source/proof・ユーザーデータ・x86・共有cacheは削除しない。

親はcodecと契約/結果を所有し、primitiveを既に凍結。独立workerはdirect-token-dirichlet/verify-full.ps1、frame_cases.rs、FULL_FAILURE_PLAN.mdと指定fullrootのみ。数値worker3ファイル/rootに触れない。sourceはapply_patchで編集。
実行前にPSparser/schema/実在path/actual importsを照合し、source/contract/guard/primitive report/compiler/runtime/旧EXE/旧frame/固定inputをpin/readlock、前後照合。child120s/stdoutstderr65536/報告512KiB。disk-budget guardは事前事後チェックであり強制quotaではない。出力前に個数×上限を見積もる。PDB/Cargo/cache/rawtraceなし。失敗root上書き/自動同条件再試行なし。source freeze/hash通知後に1run、Gitstage/commit/push/version/公開/外部書込み/追加delegationなし。

7-Zip総合超えgoalはサイズ・同境界encode/decode速度・holdout/カテゴリ・4native・製品/API統合の実証まで未達・active。primitive/full E2Eだけを完了扱いしない。

