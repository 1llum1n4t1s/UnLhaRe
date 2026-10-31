# exp_neg inverse-scale：有限同値・命令反証の結果

Windows x64、rustc1.98.1、opt3/thin LTO/codegen1、panic unwind/checked overflow。Math最終式1siteだけの変更で、旧本文との全文復元が一致する。constructor/Vec/guard/cutoff/grid/補間/エラー順は同じ。

## 実測

| 項目 | 結果 |
| --- | --- |
| コンパイル | 1回、exit0、1655.3035ms |
| finite native | 1回、exit0/stderr0、148.9505ms。速度benchmarkではない |
| 比較 | grid393312＋LCG65536＋境界30＝458878。全Result直接比較 |
| 正常/エラー | Ok458859の全bits、Err19の全メッセージ・分類が一致、差0 |
| checksum | 000c3ed9dea119fa。弱い表示証拠であり全比較の代用品ではない |
| 生成命令 | finite reference_exp wrapperのscalar div3/mul3、candidate_expはdiv2/mul4。両calls8 |
| readonly | 親11before/after/live組・raw1・全文1site復元・asm再集計・清掃台帳照合、exit0、追加compile/native0 |

命令差はこのfinite wrapper EXEだけの証拠。通常codec速度、全f64域証明、4native互換、7-Zip超えの証明ではない。候補として次の通常wire比較へ進めるが製品へ採用しない。

## 出力経路の失敗と回復

親run-nativeは、thin LTOの`--emit=link=...,asm=...`がasm指定名を無視して複数`.s`を生成したため、指定asmが見つからずnative前に失敗した。コンパイラはexit0、警告は`ignoring emit path because multiple .s files were produced`。Child CWDがprojectなので14asmがproject直下へ出た。

asm計3890289Bは事前のasm2MiB上限を超えた。一回目の経路を容量ゲート成功と呼ばない。重複ビルド・予算拡大はせず、compile完了のEXEを再利用した。UTC時刻と14件/総bytes、通常file、linkなし、共有利用なしを検査し、必要なローカルmodule asm118861Bを専用buildへ移動。残り13件3771428Bは共通Remove-CodexItemでごみ箱移動→今回分のみ完全消去→元/ごみ箱/metadata不在を確認。既存ごみ箱不変、台帳state complete。初回の事前検査はPowerShellのZ付きDateTimeがlocalへ変換される点で拒否したため、UTC DateTimeOffsetを明示して再検査した。この時点では移動・削除前で、policy拒否の迂回ではない。

`recover-native.ps1`が元failed reportとEXE/SHA、先行source/pinsを確認してからfinite native1だけを実行した。追加compile0。元report/runnerは凍結しstatus failedを上書きしない。これらのrunnerは消費済みの一回実行証拠であり再起動しない。後続の通常codec runnerはlinkだけを生成し、今回のasm経路を再利用しない。

## 保存と再検証

- 原failed report E25B175D89D6BFC799D03F635F7342BA5646CA02E55E334979233CC20F165F05
- 回復report 94EF514E399F3FDF5F918884EDE6E53A820084306707B823B84103A6A2DBEA68
- EXE 0285731721E89EABA6F66ED471F6D48134C7EC97B3BD9574BC369E2168209C87
- 必要asm B8506061CF20B9ED5F3ED473D87D10667EC6BF0E800BCA9E3124D50404C44FEB
- 清掃台帳 3A4C4C97043ED629333C0D900ADC95253CFC0F9C915B159F4EB7678D09A577AF
- 回復script 4D65518EF58E2263D1DDF78B38C56E1B2F4044693F43B9D14F760904D462AE43

```powershell
pwsh -NoProfile -File UnLhaRe/experiments/khc/hard-cut-exp-scale/verify-readonly.ps1
```

新生成物の保持量353401B、5files（EXE/asm/failed report/recovery report/cleanup ledger）。空き55020662784B。入力copy、生cases、trace0。今回の13asm完全消去は回復不可だが、必要な比較asm/EXE/source/report/手順は保持済み。他作業や共有cache/x86の削除はない。

## 次の作業

親が通常pairの先行失敗契約を保存し、同じ凍結Model/CTS/codecを静的な旧新scopeへ結ぶ。candidate poolのMath参照だけ新型へ、その他本文を復元照合する。全旧新frame478856B直接比較、各directionの全plain/typedProof14、cross全stats/Proof Debug、先行14/34/4を維持する。source/資源/通常単回内部速度のscreenは正式fullCLI/quiet/warm9/holdoutと区別する。通常速度効果はまだ未検証。GOAL active、停止なし。
