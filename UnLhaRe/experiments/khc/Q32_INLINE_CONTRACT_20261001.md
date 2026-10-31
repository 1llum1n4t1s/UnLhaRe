# Q32商補正＋LUT・inline候補の先行契約

目的: 凍結候補A3981BC...で非inlineの共通商呼出が確認されたため、商helperとCTS wrapperのinline指定だけを一変数として評価する。新アルゴリズム・数値仕様・安全性検査を追加削除しない。成功は総合7-Zip超過の証明ではない。

## 実装前の失敗条件

- inlineが効かず共通呼出が残る、またはコード増大で遅くなる。
- module参照を取り違え、旧helperまたはBayes/CTS数値変更を含む。
- opt2/opt3・反復・旧候補とのframe不一致、相互復号の失敗。
- cap/CRC/破損/既存output保持/no-clobber/状態分離の退行。
- 旧55checkや生入力readlock、proof pinが欠落し、検証範囲を縮小する。
- CPU guard不成立を速度成功と誤認する。

## 変更範囲

新 `causal-bayes-q32-corrected-lut-inline/` のcodec.rs、cts_model.rs、exact_div.rs、build.ps1、verify.ps1だけを実装担当一人が所有する。codecはCTS参照をlocalへ、CTSは商module参照をlocalへ変更する。商helper `ratio` とCTS wrapper `ratio` に `#[inline(always)]` を追加、それ以外のRust計算・制御・error・flagsを保持する。既存凍結source/EXE/proof/比較は変更しない。

親はこの契約、生成コード診断、必要な新compare、開発記録を所有する。製品/API/unit test/共有cache/x86/Git/version/公開は対象外。

## 検証と採否

旧build/verifyの方法を再利用し、新source/contractを固定し、専用 `build/khc-bwt-causal-bayes-q32-corrected-lut-inline-20261001/` へRust1.98.1/edition2024/panicabort/opt3とopt2を作る。失敗系を含む旧55checksを保持し、旧LUT候補との小fixtureと固定groupのfullframe一致・両方向crossdecodeを追加する。全CLIexit/timeout、beforeafter pinsを記録する。新Rustのみrustfmt skip_children。全E2Eは通常性能の証拠にしない。

実生成コードを凍結EXEで再確認。static call削減は動的速度ではない。独立担当は変更範囲・全raw一致・旧check包含・pin・計測条件を読み取り確認する。採用にはquiet15%、warm1+9、circular同sessionの全CLIwall比較、native固定opts、size<=483599B/time<574.5624msの元gateを維持する。不完了比較で採用せず、部分sampleを全9回に昇格しない。

保留中のQ32商補正/LUTを既採用と扱わず、採用済み研究SA-IS基準は維持する。総合性能・holdout・decode/memory・4native環境・製品統合の残要件も維持する。
