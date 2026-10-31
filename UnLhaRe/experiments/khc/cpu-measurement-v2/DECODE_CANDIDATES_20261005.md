# 復号側費用：次の候補を選ぶための静的証拠

2026-10-05。opop Performance/Hardening/Testerを読み取り専用analystに委任し、8ファイルを確認した。要求profileはanalyst既定（gpt-6.1-sol/medium）、実効モデルはこの起動結果から独立確認できない。親も該当呼出し元を照合した。実行/編集/ビルド/テスト/Git/外部書込みは委任範囲外。全変更の所有者は親。

現時点の全Canterbury対7-Zip結果は旧leaf EXEのhistorical診断である。現行sourceの復号速度とは区別する。下記は計算・コピー回数の証拠であり、速度改善の実測ではない。

| 候補 | 実コードの根拠 | 保持する契約・反証 |
| --- | --- | --- |
| active配列のprefix移動 | block/mod.rs:639の各runは先頭を削除し、rank>0なら再挿入。元長A、rank rで2A-2-r要素を動かすが、同じ結果は1..r+1を左へ動かしrへsymbolを置くr要素で得られる | rank=0は従来の削除を保持。r<=A-1検査、履歴・run・終端を保持。末尾rank中心なら効果は小さい。rank=1/A-1、alphabet縮小、sentinelの実経路E2Eが必要 |
| Forestへ直接modelをparse | packet.rs:189-196は284個のDispatchを作り、全3*1024行をForestへ再コピー。872448行*8=6979584 B/ブロック、284回の一時割当が静的に確定 | parse_nodeのdepth/high履歴swap/葉frequency/重複dispatch、Reader finishのmodel count/trailing検査を保持。確保失敗点と内部容量Statsは変わるので隠さない。最大split、高履歴、CRC再封不正metadata、encoder側Forest呼出しも対象 |
| rangeのslot/unit共有 | mod.rs:421,477からmulti_range.rs:175 consumeへ進み、slotとunitの同じ除算を再算出 | rounding gap、slot区間、切断時状態不更新を保持。Release inline/CSEが除去済みなら利益なし。機械語か実測で反証してから採用 |

優先順位：Paid/Low空枝候補の測定を先に完了し、その間はsource pinを保持する。次の小さなdecoder候補はactive prefix移動。低リスクだが小さければ打ち切り、より大きいForest固定費を扱う。3候補を一度に編集せず、旧EXEを保持し各変更の効果を分離する。7-Zipの完成ゲートは変えない。

追加仮説：uniform defaultのForestをdenseな1024行で実体化せず、root descriptor＋共有CDFにできれば空のrootの固定費も減らせる。ただしこれは候補設計であり未実装。非defaultだけの可変storage、heap growth上限、lookupの追加分岐費用、非defaultとして符号化されたuniform leafの区別、公開前の全metadata検査維持が必要。単純なdirect parseより利益が大きいかは未確認なので、先に形態を比較し、投機的cacheとして即採用しない。

独立Hardening不具合はこの確認範囲では見つからなかった。既存E2Eが上記のrank/high/rounding gapをすべて覆うとはまだ確認していない。今後の検証は公開APIまたは実CLIのE2Eとし、新unit testを追加しない。
