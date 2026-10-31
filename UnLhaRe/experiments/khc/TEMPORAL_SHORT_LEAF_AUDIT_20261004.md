# 短leaf候補の独立反証

読み取り専用担当temporal_paid_model_auditの追加調査。編集・compile/native/Git/外部/削除0。親が採否を担当。

## 判断

固定1候補の診断として実装を採る。成功・製品採用・速度利益の保証はない。

- Performance: 現532461Bから48862B削減が必要。現木を固定してheader0でも507396B、23797B超過。packet最低1554Bならtokenにも25351B以上の改善が必要。無料pure78971行はselected pure葉の件数ではない。
- Performance: split1bit＋leaf2bit mode（default/pure/raw/reserved）。default3bit、pure4/5/5bit、raw18/33/48bit。raw葉は各2bit悪化するため、少数pureの短縮だけでは総改善保証なし。最大完全展開102399bits/modelは保守上限142335bits以内。
- Performance: root defaultはouter tagだけ1bit。DP内部費用0と、検証用root serialization3bitを分離しないと費用の正当性を主張できない。既存evaluate_tileはroot defaultにもserialize/parseを呼ぶため、0bitsをそのまま渡さない。
- Hardening: CDF量子化は維持するがwireは旧方式と非互換。新候補source/kindで分離、旧資料凍結。mode11/k3 dominant3/truncated tag・index/depth5split/padding/trailingを拒否。pureは支持値2・dominant32768-2(k-1)と全CDF一致で判定。default k3は[10923,10923,10922,0]。
- Tester: pure各k各dominant計9、内部default/raw、leaf bits、split境界、root費用0の独立算術をfailure-first censusで追加。Fit→root全CDF、packet解析row loss、連結bits、全Meta、資源条件を検査。新DPの木は変わるため、旧selected CDF不変と誤って主張しない。

根拠: temporal-paid-root/paid_model.rsのquantize/build_node/write_node/parse_node/root_wire/parse_root、packet.rsのroot/evaluate_tile、e2e.rsのfixture/rejection_recovery、build/khc-temporal-paid-root-20261004/report.jsonのpaid loss/token/header。より有望と断定できる代替は今回のローカル証拠にない。

## 観点台帳

| 観点 | 担当と判定 |
| --- | --- |
| Modernizer | 親: 依存・runtimeを変えず、現Rustの既存型で実装。更新対象なし |
| Normalizer | 親＋analyst: 同じHist/quantizeを維持し、実wire費用をDPへ統一する |
| Performance | analyst: 上記反証後、短いcanonical leaf＋新DPを有界診断として採る |
| Cleaner | 親: 全tile forest/trace保持を避け、旧証拠参照は用途を分離。出荷互換でないprivate方式のみ |
| Hardening | analyst: 新mode/index/depth/長境界とsource識別分離が必須 |
| Tester | analyst＋親: failure-first有限E2E、型検査・固定実入力・直接比較、読み取り再現報告 |
| Async | 親: 非同期化なし。scratchの逐次解放、runner finallyのhandle解放を維持 |
| Intel | 非該当: 外部現在値の変更に依存しないローカル数値・wire実験 |
| Startup | 非該当: 利用者向け起動・bundleを変更しないprivate診断 |

前段基礎検証temporal-paid-root/verify-artifacts.ps1はreadonly75組/raw1成功。compile/native追加0、paid532461B/no-go。終端にも同じ基礎検証を実施する。全GOAL active・未達。
