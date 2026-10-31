# Q32商補正・凍結EXEの生成コード診断

対象はWindows x64の研究候補のみ。再コンパイルで別のコード生成結果を混ぜず、LUT候補の凍結EXEを既存LLVM objdumpで読む。圧縮処理・時間測定・製品変更・固定ゲート変更はしない。

## 再現と証拠

```powershell
pwsh -NoProfile -File UnLhaRe/experiments/khc/causal-bayes-q32-corrected-lut/inspect-machine-code.ps1
```

既存出力がある場合は、同スクリプトの `-WorkDirectory` に `UnLhaRe/build/` 内の未使用絶対パスを渡す。既存証拠を上書きしない。

- 診断スクリプトSHA256: `5709CED3737AA0618AD4070702DDB68EE8176DA6111197955F648B9C527A50C2`
- EXE SHA256: `A3981BC785F0DC3F5882EED62F49DC12C4911FD045773AEC6646417E3BCD2010`
- objdump SHA256: `B7BC838715378E58182AB04651835347BD83C23A9EB40904AE8BA88F095C74CA`
- 保存先: `build/khc-q32-machine-code-20261001/report.json`
- report SHA256: `718CD539445E517C2B885D66FE119D90CFBE2C7AFEA8CDB27C0CB878D8A1F5D7`

EXE/toolは読取共有だけで開き、前後SHAを照合。reportはCreateNewで書き、用途を終えた一時コピーは作っていない。PDBによる関数名解決は行っていない。

独立監査はpin一致、局所逆アセンブル129行の一致、全命令集計、4callの引数を確認した。129行はpaddingのint3 4行を含む。監査で未使用の終端変数を発見したため、次routine開始番地の存在assertへ補強。補強後は `build/khc-q32-machine-code-20261001-endchecked/` へ再実行してreportのSHAが完全一致することを確認し、この重複reportと空directoryだけを削除、元reportを保持した。

## 観測と解釈の境界

`0x14000af30` に始まり次のroutine開始 `0x14000b120` までの領域へ、静的な直接callが4箇所ある。周辺の引数は次と整合する。

| call番地 | 観測した引数・周辺処理 | sourceからの帰属推定 |
| --- | --- | --- |
| `0x14000a24c` | a=2^32、b=1、観測数に2を加えた分母 | alpha |
| `0x14000a4d6` | weightとpk、混合和+Q−1を32bit右shiftした分母 | posterior |
| `0x14000ab08` | a=2^31、b=2zero+1、total+1 | KTの初回 |
| `0x14000abbf` | a=2^31、b=2zero+1、total+1、cap検査 | KTの反復 |

従ってalpha/KT/posteriorで共有する商処理がcallとして残ることを支持する。関数名の厳密なPDB確認ではなく、引数・source・制御フローの照合による推定である。

領域内には `divsd` 1個、`cvttsd2si` 2個、`mulq` 4個、fallbackの `divq` / `divl` 各1個がある。u64からf64への分割変換、u64への飽和変換に対応する比較・条件付き選択、および整数残余による証明の分岐が残る。flagsの返却は見られず、CTSが使用しない診断flagsはこの生成コードでは除去されていることを支持する。

これは静的な命令数であり、実行回数・時間占有率・fallback頻度ではない。呼出回数の予測をこの4個という数字へ置き換えない。OOM用callを含む領域のcallq6個もホット経路6回を意味しない。

## 次の候補の判断

最初に試す削減は、現行商補正と同じ整数証明・fallbackを保ったまま、商処理を呼出元へinlineし、KT/alphaの定数引数を最適化へ見せる一変数実験が妥当。inlineが必ず高速になるとはしない。コード増大・instruction cache・最適化の相互作用を含むため、生成コードの再照合と全frame一致E2E、固定の正常比較が採用条件。

KTの分子は観測capにより2^62未満だが、posteriorの分子はsigned64範囲を超え得る。汎用helperを無検査でsigned castへ置換しない。signedの特殊化やSIMDは別の数値契約が必要で、今回実装しない。

最新正常比較はround9のCPU29%でfailedのまま。部分8回を採用根拠にせず、SA-IS研究基準・size483599B/time574.5624ms未満・quiet15%・nativeoptsを維持する。総合7-Zip超過・4環境・holdout・製品統合は未達。
