# Q32厳密商補正のcodec組込み契約

前工程は商30937件のBigInteger E2Eと独立監査PASS。今回の失敗条件を実装前に固定する。

- 元Q32とCTS予測/更新/数値/全frameが異なる、magic/grammar/Bayes/CRC/上限を変更すること。
- opt2/opt3またはプロセス反復の不一致、元Q32とのcross-decode失敗、復元byte不一致。
- 不正frameの公開、上書き、source/compiler/既存proof/fixture変化、所有child timeout。
- 圧縮率の悪化、速さを静穏条件なしで主張、閾値・nativeopts・CPU設定の変更。

新 `causal-bayes-q32-corrected/` のcodec/CTS/verify/build harnessのみ一人が所有する。凍結Q32ソースとhelper数値証拠は編集しない。CTS ratioだけを検証済 `corrected-quotient/exact_div.rs` へ委譲し、返却flagsは破棄。元zero denominator/productoverflowのエラー文言と順序を維持し、alpha=Q/dも同じ正確なhelperへ移す。D=Qのshift、チェック、確率検査、観測cap、更新順を維持する。codec全文はmoduleの参照先以外不変。

新root `build/khc-bwt-causal-bayes-q32-corrected-20261001/` にRust1.98.1/edition2024/panicabort/opt3 candidate、opt2 referenceを作る。fmtは新Rust sourceだけskip_children=trueで適用し既存モジュールを触らない。全source/compiler/helper/numericproof/契約/新EXE/生成入出力のreadlockと前後SHA、120秒所有child上限・finally停止・新root拒否を維持する。compile記録とfull proofを保存する。

元Q32のlocked verifyを別新harnessとして再利用し、既存正常/異常/上限/破損/出力保持E2Eを省かない。正常fixtureについて元Q32 candidateでもencodeし、元/新全frame byte一致を比較する。固定group SHA18B8...、frameは483469B/SHA7584AF15ED4A70F6AD16E278F29DBB1C4D63EACD1DD58D5164198D03D3B5D95C、全byte復元、元Q32とのcross-decodeを実行する。

この工程は正確性だけで時間採用しない。後続の正常比較は固定archive<=483599B、全CLI encode<574.5624ms、warmup1+9、同session circular/native一thread、既存quiet-hostの<=15%を維持する。4ネイティブ環境/総合holdout/製品統合は未検証のまま区別する。

Git・version・公開・製品src・x86・cache・レジストリは変更しない。生成物は再現に必要なsource/proof/rawとして保持、backup・不要反復コピーは作らない。
