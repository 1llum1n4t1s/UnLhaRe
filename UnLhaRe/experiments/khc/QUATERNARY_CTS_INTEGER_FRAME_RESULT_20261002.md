# private整数CTS frameの実E2E結果

## 判定

Progress。凍結整数5特徴poolを実range streamへ接続した新private形式 `KHQCIP01` は、一条件・一回のビルドとE2Eでpassed。固定入力の実frameは474730Bで、固定サイズゲート483599Bを8869B（約1.834%）下回った。復元2811006Bの全byte/SHA一致、全frame正準再符号化一致、正常14・異常30・model拒否16 assertion・CLI10を確認した。

これは総合的な7-Zip超えの完了ではない。正式speed/CPU、holdout/categories、4native環境、製品/API統合は未達。full_benchmark_allowed=falseを維持する。製品wire、LHA method、公開API、version、配布は変更していない。

## 凍結条件とidentity

- 契約 `QUATERNARY_CTS_INTEGER_FRAME_CONTRACT_20261002.md`: B813A1D3B41F40B615FA356411D0E1F923FA924231ADAC1FF9CB71BBD54122B1。
- model.rs: BB7DAFC75AF4763C553A15EC8619E9641FDBC6C53CC206B7DAB01B02D97547B9。
- codec.rs: 673E3759DDCB2EC17C2FB6376AB8A95F06EFE4238242CB2DD1E677E1576C3327。
- e2e.rs: 824DE9E08FA2EC069FE0D935EC7E2FE58EFD38FE813D5D49F545AD156AABE3E1。
- verify-full.ps1: C1AB88073C433560F4F73D06A9EC10E051E1EF90809F10F6A8952255C6B92D0E。
- コード前FAILURE_PLAN.md: F06DFE8EF43DD10AE99DE118C7B40D5C18283C2469EE1191997336878C0DD4C3。
- proof `build/khc-quaternary-cts-integer-frame-20261002/report.json`: 54282B、18B106BDB873BB5B1C82EBF7F7B9B6EBB17209C8E137D9332320941D0CBECB98。
- EXE `codec-o2-yes.exe`: 296448B、1E47B92B840F7211B981B367F15B216B8DAA03811C78C3261B55F37CA1765B95。before/after一致。
- frame `all.khqc`: 474730B、9867AB88CD27AE48174C9C1E9FAC65BEEE6D95C95BDE8C53DB2F0E988653BFAD。

親の全source/runner確認、別担当のmodel接続・codec/forge静的確認、payload上界の独立検算後に実行した。非Execute preflightと実行で26identity・9source/8edgeを固定。sourceのbefore/afterと親の実行後再hashは全一致。旧source/proofを変更せず、未知import/include/extern crateを拒否した。

実行はWindows x64、rustc1.98.1、bundledpwsh7.6.5、edition2024、opt-level2、overflow-checks=yes、panic=abort、debuginfo0、DEBUG:NONE、frame_audit/primitive_audit。契約でpinされたcompiler/runtime/kernel/inputのidentityはproofに保存した。2026-10-02T03:00:48.4623756Z開始、03:01:43.9584158Z終了。fresh rootへの一回だけのExecuteで、再試行/条件緩和なし。

## 実frameと復元

| 観測 | 結果 |
|---|---|
| 入力・復元byte | 2811006、全byte一致 |
| 入力・復元SHA | 18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76 |
| frame / header / payload | 474730 / 281 / 474449B |
| header fields | primary1762795、alphabet257 |
| CRC | plain433441561、payload3589341169、header1741345118 |
| runs / rank tokens / length tokens | 各889227 |
| escape | 742B、5936bits |
| branches | rank2725772 / length1099568 |
| grammar digest | 58735a2b7383d755 |
| base/pool digest | 9128444225deabce |
| CTS class observations | 889227 / 620240 / 1216305 / 889227 / 64372 / 145969 |
| CDF entropy | 3788636.714502990bits |
| CDF＋escape | 3794572.714502990bits |

encode/decode/canonicalは同じtoken、branch、class、digest、entropyを返し、先行整数pool proofと一致。digestはbase count値/pool weightsだけで、CTSやcached totalを含む全状態hashとは主張しない。実復元はhashだけでなく全2811006byteの逐次比較、canonicalはdecode→encodeした全frame byte比較を行った。payload実bits3795592とCDF＋escapeの差は1019.285497010bitsで、実frameサイズによってゲートを判定した。

CLI childの観測wall timeはencode12008.7067ms、decode12536.2343ms、canonical24564.4469ms。これは一回の正しさ検証・集計付き診断であり、正式benchmarkのmedian/CPU測定ではない。574.5624ms/CPU15%ゲートを通過したとは言わない。正式observer/protocol変更の確認待ち条件も変更していない。

## E2Eと失敗拒否

RAM正常14件で入力→圧縮→復元の全byte一致14、再圧縮の全frame一致14。constant長のescape境界、全256byte、疎alphabet、固定LCG4096、固定textを含む。IEEE CRC32の独立fixture `123456789` も一致。

RAM異常30件はコード前計画の名と理由すべて一致。短いheader/旧magic/不正fields/quota、CRC/packed alphabet、range prefix/gap/truncated/trailing/termination、sentinel/primary/LF cycle、active不足/残存、escape非正準/4bytes継続/remaining超過を正常guardで拒否した。forgeによるCRC修復はRAM E2E内だけで、正常codecのguardを無効化していない。

Model named14、rejection assertions16、CAP exact success1。stale/改変CTS snapshot、prefix/component/context/node/symbol/child/row/weight/count、CAP exact/over拒否時に、全base count+cachedtotal、全pool weights、CTS全raw+weight/history/observations、serial/branch/prefix/rescale/cold/entropy値を直接比較し不変だった。任意pure-helper改変に対する外部API保証ではない。

CLI10件はzero encode/decode2成功、既存16B出力へのencode/decode2拒否、missing source2拒否、missing parent2拒否、unknown operation/引数不足2拒否。既存16B全byte保持・拒否出力の不在を確認。16 child recordsはすべて予定どおり終了し、成功stderr空、拒否8件は期待exit1/理由だった。

## 容量と清掃

新rootの予算8MiB、事前peak予約5434775B。実行後はEXE/frame/reportの3fileだけ、合計825460B（約806.1KiB）。Cargo/PDB/cache/rawtrace/table/入力複製は作らなかった。OS強制quotaではなく、生成前予約と前後guardである。

temporary台帳に絶対path/用途/削除条件/identityを保存し、生成したrestore.tmp2811006B、empty.input.tmp0B、empty.frame.tmp74B、empty.restore.tmp0B、sentinel.output.tmp16Bを用途終了後削除した。生成しなかったmissing encode/decode出力2pathは不在。リンク/範囲/所有codec process0/exclusive leafを確認し、同一PowerShellの非再帰Remove-Item -LiteralPathで削除した。親の最終確認でもtemporary残存0・所有EXE process0。削除したのは再生成可能な検証一時物だけで、復元比較/identity証拠とframeを保持している。既存データ・共有Cargoキャッシュ・x86・ごみ箱は触っていない。

## 残作業

次段は現モデルの圧縮サイズを維持した高速化の調査。現在の診断時間からは速度達成を主張できず、profileを行うなら新契約/容量予算で一度の小さい証拠だけを残す。一般CTS CAP/配布Limits対応、payload quota、holdout/categories/4native/製品API統合は別途必要。heap/write/sync fault injectionと一般handle-safe抽出も未検証。8MiB以内の全一般入力の成功保証はしない。ゴール「7-Zip超えをするまで！」はactive・未完了。
