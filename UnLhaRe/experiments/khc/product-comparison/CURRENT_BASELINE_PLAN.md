# 現行研究方式との比較：実装前契約

既存 `experiments/khc/mod.rs` の Standard、Range、dictionary1MiBを変更せず比較入口だけ設ける。
現行LHA製品APIはfilesystem入力で、RAMブロックと同じI/O scopeではない。
したがってこれは旧KHC0LAB StandardからKHC1BLKへの比較であり、LHA利用者経路を測定したとは呼ばない。

失敗候補：stdin過長、未知mode、frame過長、decodeサイズ過大、旧形式混同、pipe漏出、時間/RAM超過、復元不一致。
stdin/stdoutは1MiB(+40B header)以下、旧codec max_output1MiB、memory_budget64MiB。
外部process ceiling64MiB/60s、既存比較と同じ入力・暖機1+9測定・CPU15%/反転順序を維持する。
全frame metadataをencodedサイズへ含め、raw/frameのdisk複製0、既存report上書き0。
追加sourceとreportは256KiB、共有compile増分256MiB、空き5GiBを超えない。
初回エラーも保存し、未実行・中断を性能成功へ換算しない。
