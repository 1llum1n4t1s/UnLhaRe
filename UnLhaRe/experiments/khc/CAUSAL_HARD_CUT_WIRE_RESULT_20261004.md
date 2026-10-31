# Hard-cut実frame診断結果（2026-10-04）

親がrun-native.ps1を単回実行、exit0。compile1、native2（有限selfcheck、固定入力各1）。これはprivate研究形式の正当性・サイズ診断であり、総合7-Zip超えではない。

| 確認 | 結果 |
| --- | --- |
| 実frame | 478856B = header285B + payload478571B、固定上限483599Bより4743B小さい |
| 固定入力 | SHA18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76、2811006B全byte直接復元比較 |
| モデル一致 | encode/decodeのtyped Proof14全Eq・full stats一致。primary全node一致の主張なし |
| 有限E2E | 正常14、全plain/Proof14/再frame比較14、破損34厳密reason、短depthheader4 |
| 実メモリ | 固定WS54800384B/private51499008B、selfcheck WS15630336B/private12718080B、双方160MiB以内 |
| 容量 | 出力EXE410624B + report92457B = 503081B。frame/plain/input追加保存0。終了空き61203218432B |
| 時間 | 単回診断encode3775.1837ms/decode3864.9464ms。正式quiet/warm1+9条件未確認、速度目標未達 |

新private magicはKHQCHC01。原float codecから数値処理無変更の接続5置換。18source/17edge/108793B、wire_auditのみ有効、primary/frame/primitive audit/test無効。旧float magic拒否確認。payload CRC2323132388/header CRC735823295、plain CRC433441561、cdf f64 bits4705461279319865477はencode/decode同一。固定入力再encodeは0であり、全frame正準性の再encode確認は有限14件だけ。

保存証拠：build/khc-causal-hard-cut-wire-20261004/report.json SHA B24F7E1953CD556BF14E3EB2191E6D043A832EB5002624BDD18C4202DF635871、EXE SHA D53FA8C1AE4F0976814B14796477B7FB9B366DDC4A52EFD88AC5A2819B5A8AE7。

親のverify-readonly.ps1（SHA D89B2B9A324C406A1F9A7D1C01BD16B7836F1A0631AD89C7219E2BFD6B59E3FA）単回exit0：115組before/after/live識別、EXE、raw stdout2と保存JSON、全grammar/count/実サイズ/source RAM式/双方実peak/出力形状を照合。追加compile/native0。

残る正式条件：速度、独立holdout/category、完成書庫metadata/API、Windows/macOS x64/ARM64。製品20dirty/Git/version/API/x86/旧証拠不変、削除なし。GOAL active。

次候補：engine.rs:11–12の成功時Stringエラー構築を遅延化する2箇所。readonly担当は同原因を確認したがLLVM除去・物理allocation・速度利益は未測定。model.rsの3箇所は別候補とし混ぜない。旧凍結sourceを保持し、新private構成で数値・frame・エラー同値を先に確認する。
