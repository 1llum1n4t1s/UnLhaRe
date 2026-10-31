# 混合再利用codecの性能比較条件

## 実装前の失敗条件

- 入力・EXE・source・契約・proofの不存在、長さ/SHA不一致、readlock中の変更、reparse point、既存workへの上書き。
- CURRENT数値証拠の99checks/103CLI/65536算術records/11267Model records/87identities、Prediction544B・Node16B、build/full証拠の成功条件や全raw evidenceが欠落。
- 清掃済みの旧mixture numeric 2roots/98中間rawを正式proofに追加する、旧split全proof/readlocks又は旧LUT cleanup adapterを省く。
- 元compareの計測7helper、quiet15/preflight5/全child前後、warm1+9/circular3codec、native options、120秒deadline、full CLI wall、memory/thread pollingを変える。
- group2811006B SHA18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76、11件metadata/body又は全frame483469B SHA7584AF15ED4A70F6AD16E278F29DBB1C4D63EACD1DD58D5164198D03D3B5D95Cが変わる。
- 固定size<=483599B/strict encode<574.5624msを緩和する、quiet違反/途中失敗を成功にする、部分samplesの採用、自動再試行、CPU設定変更や他process停止。
- Predictionのsnapshot配列copy/544Bへの増加やLUT構築をfull CLI時間・メモリから除外し、静的演算削減や数値greenを性能結果として扱う。

## 凍結対象と実行境界

旧split compare SHA052E6B088E35D49DDEC29E0D7174C2909BE2F6FA650978F066B99C50486237DDを全文cloneし、source/契約/proof追加、DFS/readlocks、candidate/control pins・ラベルだけ更新する。計測7helperと旧LUT cleanup adapterを保持し、Parserとhelper AST完全一致を静的検証する。独立監査・凍結後、未使用の `build/khc-bwt-causal-bayes-q32-mixture-reuse-20261001/performance` へ1sessionだけ試行する。

候補 `build/khc-bwt-causal-bayes-q32-mixture-reuse-20261001/candidate.exe` SHA4B39B65E931479E151322E92E69198F3ED6A6A6A5E3F1DBFB389BC02DEF19446、control旧split EXE SHA471E62E5F804C74A498B266C458239C4B16A242172AF3B455CA0D5D8FB279D1C。同model/precision/grammar/SAIS/全frameで、変数は混合floor・remainderのsnapshot再利用とlive-weight fallbackのみ。

CURRENT numeric `build/khc-q32-mixture-reuse-numeric-20261001-model-layout/report.json` SHABFF074A286B71CA770059B4CD87B1037A982EC7B28A1BD48378F5E9914E45C72、build SHA06113576C0D2DC714E6C26B0C3B342C3977749F4BA270D5035AE73E8609382E8、full SHAB0AE7D16901B3755105914885C49FE44AF91BFCD8DC524FAD34F8428D49CFE56（79checks/154CLI）を既存proof DFSへ追加する。全identities/input/oracle/rawを同一readlockへ含める。

observer SHAE66D39AE8BCDAD63BC7D3FC467D4C85E950261749D457D33C4BFA9D3ED13FFBF、native7za SHAEDBEE35370E14030E4C785CF88200F42DC651C1EB4217C1E3963C38A12F099B0、mx9/LZMA2:d=64m/mmt1/solid/時刻metadataなしを維持する。最終decode/nativeSLT・全9測定・全pinsが成立したsessionだけを局所比較の根拠とする。busyはfailedで止め、自動再試行しない。

候補/controlの全CLI wallとtotal archive bytesで判断する。固定歴史gateと同session paired ratioは別々に報告し、decodeは出力境界が異なる診断値に留める。Windows x64/Canterbury開発corpusの局所結果と4native/holdout/製品統合/総合7-Zip超過を区別する。準備工程ではビルド・CLI・速度測定を実行しない。製品/x86/外部書込み/Git stage・commit・push/シークレット/CPU設定を扱わない。
