# 狭い整数refinementの完全codec同値（実装前契約）

数値成功の狭いhelperを、Q32因果schedulerのheavyだけへ導入する。凍結Q32精度、KT count、switch alpha、scheduler/confidence/journal、Bayes、primary、BWT、grammar、range、header/magicを変えない。完全frame483496BとSHA `CF62CD2324B4CF889CDDDB25C9508C28E4BD4D24217B93BB7D4FF9318C3EAD12` の維持を必須にする。失敗したら閾値を緩めず停止する。

失敗計画:

- tableをTree/Modelへ渡す際の取り違え・predict/updateの順序変化: 旧heavy/KT/scheduler/codecからの明示置換の全文対応を入口で確認し、旧83identitiesを固定SHAで現在値へ照合する。
- seed初期化・allocation・追加u64中間のoverflow: 数値report `AB03ECAD9DC5BD8109792C85B6D4F94433064AC375A38A0975E4FD567B6DB68C` とhelper `01EA52E84D8725AB3F4A0B85999DC21598C18A330FA4101E0ACE7720D06674A3` を保持。通常opt3とoverflow-checks=yes opt3を別々にビルドする。
- 完全codecの長い履歴・fallback・丸め・magicの変化: 空/単byte/全byte/反復/周期/固定seedrandom/固定groupで、2構成frameを旧Q32の保存済みnative frame全byteへ比較。両構成の復元SHA、旧native decoderによる新frame復元、旧frameを新decoderで復元を確認する。
- schedule件数だけ合ってpayloadがずれる: scheduleと完全frameの両方を比較する。内部全stateの独立oracleや四nativeまで証明したとは主張しない。
- 安全性の後退: 既存magic/header_crc/payload_crc/truncated/trailingの5破損を新decoderで拒否し、出力なしを確認。encode/decodeの既存出力保持・入力欠落を実CLIで確認する。cap/reparse全境界や製品parent-handleの証明をこの研究CLIへ読み替えない。
- 重複証拠肥大化: 既存入力/基準frameをread-only共有し、新生成は2候補EXE/PDB、frame/復元、簡潔なreportのみ。見積り<32MiB、256MiB容量チェックを開始前/終了時に実行する。生数値列・全トレース・新Cargo cache・外部書込みを作らない。

旧基準は `build/khc-causal-expert-scheduling-20261001/report.json` SHA `370534F32A979FE2768CD60C29DFBD8342CD7B358C15C4D510945B8F8DD35E7A`。候補は独立 `causal-integer-refinement/` と `build/khc-causal-integer-refinement-20261002`。rustc1.98.1/compiler SHAは数値段階と同じ。サイズ上限483599B、全CLI encode median<574.5624msは維持し、本工程で速度を測定しない。速度採用は実機・静穏・全CLIの別固定比較が必要。
