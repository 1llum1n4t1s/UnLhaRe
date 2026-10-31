# 完成prototypeの性能検証契約

`full-e2e-final/report.json` SHA `0AE7EAB04A5E58DE91AB1F74912F332D1FF6F2FC95D3A29DC0030F22A7307E37` は36 checks/61 CLI、完全frame483,468 bytesとopt3/opt2復元を確認済み。性能測定前に、candidate `4C4D9D66EA0DE8174BF436D7222BC5CCF8F42BD03EF7A1DCFE030FAAD8322ABD`、7za `EDBEE35370E14030E4C785CF88200F42DC651C1EB4217C1E3963C38A12F099B0`、固定group/source/modules/toolchain/manifest/harness/OS/CPU/power schemeを確認する。前後変更・非決定性・復号/metadata不一致・timeout/nonzeroなら成功report禁止。

測定は同じgroupで、candidate全frame、同じserialized groupを包む7z、元11fileのnative-solid 7zの3系列をwarmup1＋9反復、順序を循環して先頭回数を均等にする。7zは既存baselineどおりLZMA2/dict64MiB/mx9/mmt1/solid on/ordinal order/mqs off/times off。candidateはthreadを起動しない凍結source・単一process。sampled OS thread数と「設定された圧縮worker数」は区別し、CPU時間0の未観測threadから厳密なlifetime単一threadを主張しない。build/他benchmarkと重複させず、CPU affinityは従来同様固定しない。

wallはprocess launch前からexitとstdout/stderr drainまで。PeakWorkingSet OS値とsampled PrivateMemoryは区別。thread/private pollingは要求1msで、実poll間隔/取りこぼし/競合を保存する。各系列の初回/最後にdirect decode/hash、native11file metadata/1solid blockを検証し、中間archiveは復号済み初回SHAとの完全一致で照合する。decode時間は出力が1group対11filesで違うため採否比に使わない。

固定gateはsize≤483,599、encode median<574.5624msのまま。今回paired中央値/ratioは固定historicalgateと別に報告。sizeだけ、group-7zだけ、decode出力境界差を総合勝利へ読み替えない。native categories/holdout/portableformat/productAPIは未達。今回測定基点は `build/khc-bwt-causal-bayes-full-20260930/performance/`、不要duplicate archiveは結論とhash証拠を残した後で対象/ancestor/process確認をして清掃し、policy拒否を回避しない。
