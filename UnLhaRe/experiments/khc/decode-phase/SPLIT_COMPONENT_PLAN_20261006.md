# 次候補：rank/length coder状態の分離

2026-10-06 JST。除算なしは速度失格、同class隣接合成はgrammar枝7.08%削減で事前20%未達。二案を再調整しない。次の問いはMDL全runに共通するrank/length両成分が、1つのrange状態を交互に更新する依存を外せるか。現mod.rs:678/687の2tokenは一つのDecoderへ直列接続し、historiesはcomponentごとの3class（互いに非共有）である。lengthのlimitは先に分かるremaining.min(256)、rankのlimitはactive_len。形式識別された別研究frameで2coderのstate/streamを分け、モデル分布・branch履歴・BWT/Forestは維持する。

予定payloadはLE32 rank_stream_bytes＋rank range stream＋length range stream、両者最低5B終端を全費用に含める（従来単一streamより最低9B追加）。rank/lengthのroot slot選択を独立stateで準備できる可能性があるが、速度効果は未検証。partial prefix・k1・escapeを保持し、escapeはlength streamだけ。active/sentinel/初出順/残長/最終双方finishを検査する。新magicを用い旧frame/旧decoderはそのまま、LZ/storedはmarkerとCRC以外旧方式。同stream二分を独自圧縮原理とは称さず、依存分離の実装寄与として測る。

事前失敗：rank/length境界length overflow・最低5B・余剰/切断/中間gap・片側非正準終端・componentやhistory取り違え・length escape誤配信・各component branch/Meta違い・active挿入/最終seen/CRC違い・片側巨大出力/一時2capacity二重計上・stored fallback時の片側残存・旧新相互拒否。有限standalone E2Eで正常全byte/新旧format拒否、raw32以上/既存11・異常後復帰、source正規化・旧frame/public復元、2streamへ各成分のinterval列が同じことを逐次独立確認してから性能へ進む。

screenは各MDL frame増加<=16B（payloadヘッダ/2終端等すべて込み）、全体増加<=8*16B、warm1+9 paired通常/独立逆順で両集計decode>=15%短縮、encode増加<=5%、各MDL10%以上decode悪化0。通常失格なら追加逆順/第三回を実行しない。合格は本線統合と実native全書庫/真正未見/7-Zip総合の元固定gateへの進行条件であり、達成そのものではない。速度不足や率悪化時は同方式の係数sweepなしで棄却。

資源は既存rustc1.98.1/rlib/共有Cargo6163555929B増加0、新source1MiB/1work8MiB/report128KiB/compiler512MiB60秒/child64MiB60秒/suite180秒/CPU静穏開始15%最大60秒/空き5GiB+8MiB、PDB/plain/frame trace disk0。二stream実容量と再確保中のlive容量を64MiB codec gateへ含める。親sole editor、局所独立analystの反証、本線/旧証拠/共有cache/x86/version/Git/外部writeは変更なし。現時点は設計未実装・未測定である。
