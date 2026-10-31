# 全決定静的モデルの実行台帳

2026-10-05。最新GOALはactiveであり、調査報告だけでは完了しない。本台帳は小規模試作段階の証拠であって、製品の圧縮・展開・性能を証明しない。

## 変更前の関連基準

`UnLhaRe/experiments/khc/paid-code-tree/verify-result.ps1`を既存結果に対して1回実行した。exit 0、status readonly-passed、照合172組、raw record 1、compile 0、native 0、書込み0。既存screen 484286B（token 478416B・metadata 2791B・借用side 3079B）、旧size目標との差687Bを確認。これは既存検証器の再照合であり、新方式の実測ではない。旧compile由来のstyle warning 1件を保持する。

新出力先`UnLhaRe/build/khc-all-class-static-20261005`に対して`disk-budget.ps1 -MaxRunMiB 8`を事前実行した。使用0B、上限8388608B、最低空き5368709120B、観測空き34982006784Bで成功。追加Cargo target、入力複製、巨大モデル取得は行わない。事後確認はnative終了後に行う。

## 有限E2Eの適用分類

| 分類 | 先行故障モデルと観測 | 実行状態 |
| --- | --- | --- |
| 正常・境界 | 空、1byte、全256値、反復、skew、全class、prefix、k=1履歴がモデルpacketを通り整数CDFと再生lossが一致 | 未実行 |
| 異常・型/形状 | packet切断・余剰・不正table/bit長/深さ/支持/総量/paddingがpanicではなく拒否される | 未実行 |
| 状態回復 | 異常入力の後、同じprocessで正常packetが成功し汚染しない | 未実行 |
| 資源 | 実capacity・同時寿命・OSメモリを上限と照合し、出力8MiB・compile60秒・native120秒を守る | 事前容量のみ成功 |
| 並行・chaos | この段階は逐次RAM-onlyで共有状態・外部I/O競合なし。製品統合時の公開競合・キャンセル・途中失敗へ回す | 今段階は非適用 |

正常と異常は別source fileに置く。有限入力合計上限32KiB、固定groupは既存2811006BとそのSHAを利用。大量のCDF・input・packet traceをファイルへ保存せず、直接比較の件数・不一致・集計を保存する。sourceの編集停止と識別値が揃った後で親だけがcompile/nativeを実行する。

本段階では完成frame、payload復号、逆BWT、Rust API/CLI往復、Zstandard/LZMA2同条件比較は未完了。モデル一致や理想bit数を、完成codecの復元成功や速度優位と呼ばない。
