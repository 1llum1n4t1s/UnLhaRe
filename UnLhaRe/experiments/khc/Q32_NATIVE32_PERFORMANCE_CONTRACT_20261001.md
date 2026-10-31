# guarded64/32商の性能比較条件（未実行）

目的は新native32 codecが同じ書庫/復号契約を保持したまま、全CLIでbalanced KT controlとnative7-Zipに対して改善するかを反証すること。正しさ成功を速度成功へ読み替えない。

凍結候補は `build/khc-bwt-causal-bayes-q32-native32-20261001/codec-native.exe` SHA `44CF635A18CF73E14E968A63C5A0EC4534FE47A4E277D7F818C32E1EEDE740C3`、codec E2E proof `78F3D20CCD1764A94AC237976D96BE4CA8095935E136C4D13738E3F4BD2708C0`。controlはbalanced KT EXE `7E149D682025E4E03EDC32B6999A91C139991DBC834017EF9A15F88EA9290BF0`。このペアは元mixture-reuseをcontrolとした前回compareとは別で、効果を合算しない。

| 固定条件 | 値 |
| --- | --- |
| group | 2811006B / 18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76 |
| 新/control全frame | 483469B / 7584AF15ED4A70F6AD16E278F29DBB1C4D63EACD1DD58D5164198D03D3B5D95C |
| native baseline | 7za26.03 / 1335296B / EDBEE35370E14030E4C785CF88200F42DC651C1EB4217C1E3963C38A12F099B0 |
| size gate | 全container <=483599B |
| wall gate | launch前開始、exitとstdout/stderr drain後停止、中央値<574.5624ms |
| rounds | warmup1+measured9、3codec circular order、各先頭3回 |
| quiet | observer E66D39AE8BCDAD63BC7D3FC467D4C85E950261749D457D33C4BFA9D3ED13FFBF、pre5×1秒・全子before/after<=15% |

nativeはgroupの11ファイルをmanifest順のnamesでsolid圧縮し、`-t7z -mx=9 -m0=LZMA2:d=64m -mmt=1 -ms=on -mqs=off -mtm=off -mta=off -mtc=off` を保持する。group自体だけをnative圧縮して比較境界を変えない。round0/9で直接復号・全本文SHA/metadata検査、他roundは直接復号済み初回と全書庫SHA一致必須。新/controlはgroup1ファイル、nativeは11ファイル出力なのでdecode時間を同等境界の勝利判定に用いない。

実装前条件: 既存balanced compare SHA `869873F5AC295B3ABF0392824CA737DD1420A3E01B93DFB39A459A589E6F41B8` の7measurement helpers・process計測・timeout・memory/thread polling・median・native listingを保持しAST全文対応を確認する。今回使用するcurrent sources/compiler/新proof/旧direct frame/control/native/group/manifestをreadlockし、終了時にも長さSHAを照合する。旧履歴の再帰証明を捨てて成功を主張せず、直接依存する範囲と継承証拠を明記する。

新workは `build/khc-bwt-causal-bayes-q32-native32-20261001/performance`。既存work拒否。負荷guard・timeout・source変更・archive非決定性・復号/metadata不一致でfailed、no adoption、no auto retry。他プロセス停止/CPU設定/閾値緩和を行わない。preflight拒否なら測定が始まっていないことを明記する。性能scriptはまだ未実装・未実行。本契約は総合7-Zip超えの証明ではなく、holdout/4native/peak memory公平性/製品統合は別に必要。
