# 通常実行の lazy-error wire 検証

## 結果

Windows x64、独自 allocator なしの通常実行で診断条件を通過。compile 1、native 2、各 exit 0。親の読み取り専用再照合も exit 0、追加 compile/native 0。

- 圧縮 2327.9594 ms、展開 2201.5761 ms。単回の内部診断時間であり、同条件反復・正式 CLI 速度ではない。旧通常診断 3775.1837 / 3864.9464 ms は参考値のみ。
- private frame 478856 B = header 285 + payload 478571。サイズ上限 483599 B に対して 4743 B の余裕。
- 復元 2811006 B を全 byte 直接比較、同型 Proof 全14フィールド一致、encode/decode 全 stats 一致。凍結旧結果との全 stats / Proof Debug 一致。
- 有限 E2E は正常14、破損34、短い header4。凍結旧 E2E 全 JSON と厳密な拒否理由が一致。
- fixed 実 peak working set 54800384 B / private commit 51490816 B。selfcheck は15458304 / 12640256 B。
- 出力519373 B。終了時空き59985592320 B。8 MiB 予算・空き5 GiBチェック。今回削除なし。

## 証拠

- `build/khc-hard-cut-lazy-wire-20261004/report.json` SHA256 `3827A0AA200CF655B0F0DE816DAFB4817637ABA296318A5E677A923AB653F75B`
- 実行ファイル SHA256 `0DC016681D860862027E5AC804A9EE61FAF694302451A97B03A527A272E2E007`
- `hard-cut-lazy-wire/verify-readonly.ps1` SHA256 `1B0D3E7F7A3D2F1AA72962DF1069531274FFA3BFC07C7FF4F2A31378B4E40828`
- source18 / edge17 / source108841 B。140 before/after/live組、raw出力2件、資源算術、出力形状を照合。

## 未達・限定

通常 fixed 呼び出しでは旧新 frame の全 byte 比較は行っていない。全 frame 直接比較は前段の計測付き実験の証拠であり、混同しない。今回 fixed 再圧縮0、有限14例は再圧縮済み。

速度ゲート圧縮574.5624 ms / 展開47.3884 ms、quiet条件・warm1+9・holdout・製品完成書庫/API・4環境 native は未達または未検証。総合7-Zip超え・採用を宣言しない。GOAL active、作業継続。

次段は Model の3箇所の成功時エラー String 評価を取り除く別 private 候補。同時に予測計算の高費用処理を調査する。浮動小数演算・更新順・エラー文字列は変更しない。
