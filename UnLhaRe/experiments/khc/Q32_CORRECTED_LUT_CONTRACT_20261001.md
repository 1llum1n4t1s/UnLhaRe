# Q32商補正＋Bayes対数表の一変数比較契約

前goal turnは商補正codecの46checks/72CLIと独立監査によりprogress。quiet20%拒否は速度証拠ではない。同じ候補/同じ区間での再試行をせず、次の計算削減を検証する。

## 仮説・対照

現Q32商補正ではBayes各bitのcomponent lossに2回のlog2が残る。有限Q15入力の元式と同じlog2値をstream所有表へ格納し、更新の表参照に置換する。既存log-table数値proofは全32767Q15×両bit65534入力を含み52checks/52CLIでWindows x64の元log2 bits・混合Q15同値を確認済み。これは時間採用ではない。

新候補は商補正＋LUT、対照は凍結商補正のみ。商補正そのものの高速化が採用済みだと仮定せず、表追加の差だけを切り分ける。後続のnative7-Zipと固定総合gateは維持する。LUT追加容量262144Bと全streamでの表構築時間をencode/decode CLIに含める。exp2、混合順、loss順/精度、CTS、SA-IS、grammar、wire、CRCは変更しない。global/共有cacheは使わない。

## 実装前の失敗条件

- 元Q32/商補正と全frameが異なる、component/Q15/lossの経路変更、constructorの?伝播漏れ。
- table index0/32768参照、one補数誤り、表構築費用を比較から除外すること。
- finite/loss/cap/拒否/no-clobber/CRC/metadata検査の欠落。
- source/proof/EXE/inputの変化、無許可の旧proof再実行、上書き、timeout、失敗時の公開。
- cleanup済み旧rawが不存在というだけで新proofを捏造/古い52CLIを成功再実行と呼ぶこと。
- 非静穏時間の採用、ゲート・observer・native設定の緩和。

## 所有と検証

一実装担当は新 `causal-bayes-q32-corrected-lut/{codec.rs,build.ps1,verify.ps1}` と新 `build/khc-bwt-causal-bayes-q32-corrected-lut-20261001/` のみを所有。商補正codecをcloneし、Bayes moduleを既存log-tableへ、CTS moduleを凍結商補正CTSへ向け、encode/decode双方のBayes Model::newへ?を加えるだけ。古いsource/model/helper/proofは編集しない。parentは後段のcompare/docのみ所有する。

新Rust sourceはskip_children=trueでfmt。compiler固定Rust1.98.1/edition2024/panicabort/opt3,opt2、source/support/compiler/proofのreadlock/前後SHA、所有child120秒・finally停止、freshroot/祖先nonreparse/CreateNewを維持する。

前段商補正fullverifyの46checks/72CLIを新scriptへ移し、全旧checkを保持する。7小fixtureと固定groupは元Q32および商補正のみとのraw全byteframe一致を確認し、opt2/opt3/反復/crossdecode/復元byte、全異常系を検証する。固定frame483469B/SHA7584...、group2811006B/SHA18B8...。

既存LUT numeric proof SHA F09A9C... とcleanup SHA3ACCEFD...は不変。必要な全q×両bitのmaximum入力393216B、direct/table/table-opt2各round0出力1179648Bなど現存rawを固定し、同bytesを確認する。削除済round1重複は既存receiptとround0同一SHAを照合して説明し、全不存在rawを使用前readlock済みとは主張しない。4環境/libm間の同値は未検証。

正確性・独立監査の後だけ、同候補で一度の新performance rootを試行する。通常比較の計測helper/全CLIwall/warm1+9/circular/nativeopts/quiet15%/size<=483599B/time<574.5624msは不変。結果が出るまで速度・採用は未判定。製品/Git/version/公開/x86/cache/レジストリ/他process変更なし。raw/proofを再現成果物として保持、backup/不要反復copiesを作らない。
