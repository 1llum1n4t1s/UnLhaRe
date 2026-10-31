# 更新された総合GOALの完了条件

2026-10-05のユーザー更新を正本とする。7-Zip超えまで継続し、容量節約、競合より現代ハードウェアを活かす高度な方式、昔の計算資源では難しかった計算による速度と圧縮率の向上、仕様表で確認できる違い、AIを利用した攻撃にも備える堅牢性を追加した。小さい費用screenだけで完了にしない。

## 検証台帳

| 要件 | 完了を示す証拠 | 現在の判定 |
| --- | --- | --- |
| 7-Zip総合超過 | 固定同input/CPU/thread/RAM/静穏条件、全書庫483599 B以下、全CLI encode574.5624 ms未満・decode47.3884 ms未満、warm1+9全sample、holdout/カテゴリ、実公開経路、Windows/macOS x64/ARM64実検証 | 未達。費用screen484286 B、teacher0/frame0、完成基点はsize478888 Bだが速度約2秒。 |
| 容量節約 | 各工程unused output、8MiB上限/free5GiB guard、2小artifact、copy0、資源台帳、用途終了の自作一時物だけ規定清掃 | 現工程実行済み。paid-code-tree758495 B/2files。共有cache・他作業・証拠は維持。全開発容量の将来保証ではない。 |
| 現代ハードウェア最適化 | 仕様表のISA family別 supported/実行時dispatch/実際使用/未使用/未実装を分離、同入力scalar一致、境界/非対応CPU fallback、実同session速度/RAM効果、4native | 未達。LZ研究sourceにAVX2比較/dispatchあり。現在のBWT静的model screenに流用したと主張しない。NEON/AVX512/新ISAの実装や効果は未確認。 |
| 高度な新方式と計算方法 | 採用アルゴリズムと競合の比較、計算量/状態数/アクセス量/並列依存/学習費を明示、metadata全費用・独立decoder・全性能・holdoutを測定 | 研究中。SA-IS/anchor/有料MDL等の局所証拠を全性能に拡大しない。候補探索量やメモリを増やすだけでは優位の証拠にならない。 |
| 目に見える改善 | 保証・実装・測定・計画を分けた仕様表、圧縮率/速度/MiB毎秒/peak memory/対応ISAの再現可能な結果 | 研究ごとのRESULTは存在。総合仕様表の確定値は未達。命令の個数をISA family対応数に混同しない。 |
| 攻撃者の能力を高く見た堅牢性 | 全reader/writer/API境界、長さ/整数/予算/深さ/状態/公開順検査、破損・境界・有界mutation/fuzz・資源枯渇・回復E2E、独立source監査、回帰コーパス、実platformでの実行 | 新metadataのfinite破損検証は成功。全codec/API/OSの包括的証拠としては不足。AI無敵や安全性10倍は主張しない。 |

## 仕様表の表現境界

暗号化は例示された可視改善項目として扱う。現HIGH_COMPRESSION_DESIGN.md:212は暗号化・認証を初期仕様外とし、CRCは破損検査で認証ではない。実装していない暗号を最新対応と表記しない。将来暗号化を採用する場合は自作暗号を設計せず、別の認証暗号/KDF/nonce/改竄拒否/鍵保持/公開前認証の契約と独立検証を先に設ける。暗号方式を今回の葉候補に紛れ込ませない。

「安全性10倍」は比較基準・攻撃モデル・指標・測定がなければ意味がない。代わりに検出した不正入力種類、最大資源、境界チェック、拒否理由、修復済み独立指摘、回帰検証の範囲を記載する。未知の脆弱性がない保証をしない。AI攻撃は新しい信頼境界ではなく、既存の不信入力を高度に探索できる攻撃者を想定する。

## 次工程と所有

leaf-mode-choiceは最大6固定合法CDFからloss＋実wire料金で選択する4file実装。Node/Forest容量を維持してheader/token削減を測る。前段の符号表を再学習/価格sweepしない。これは更新GOALにも沿うが、CPU最適化や総合優位の完成証拠ではない。

全速度の主因調査として、共有teacherを完全に外す全6class静的有料modelの最小経路を独立readonly担当へ照会した。現在class2/5の静的置換では共有weights/count/CTSの更新を省略できず、35.6%wire置換を速度削減率にできない（STATIC_TEACHER_STATE_AUDIT_20261005.md）。全6classも有料metadata・学習・メモリ・独立decoderを払えなければ採用しない。有限lane/SIMD等を依存除去の証拠なしに謳わない。

既存dirty/product/x86/version/依存/Git/外部書込/削除は変更しない。予算・静穏guard・完了条件を下げない。元GOALはactive、停止/完了扱いにしない。
