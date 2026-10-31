# hard-cut private frame：コード前の有限E2E契約

2026-10-04、第一段階。PLAN SHA `1B43E1AD5CCA2003033E4B8D3A56B656B66821A373869E36211924D6CA52CD50` を全文確認。編集対象は本書と e2e.rs だけ。codec/probe/runner/adapter はまだ作らない。元 e2e.rs SHA `81BD12AC0C240E3FB51EA0E6A7F20FA22BB5278067F709FA53BB8560FDA734E5` と全旧source/evidenceを変更しない。

正常系はRAM input→encode→decode→全plain直接比較→再encode全frame直接比較。encode/decode の型付き Proof14 全field Eq を検査し、grammar/base digest/branches/classes/entropy f64 bit の既存比較も維持する。これは全primary NodeState比較ではない。全state有限oracleは前工程の別証拠であり、今回のframe検証へ読み替えない。

## 先行fault一覧と固定fixture

- 新magic KHQCHC01 の正常受理、空/singleton/length escape境界、全alphabet、sparse highbyte、固定乱数、反復textの往復不一致を検出する。14入力：empty、constant0長さ1/2/255/256/257/383/384/16639/16640、all256(1024B)、sparse-high255(64B)、LCG4096(seed1831565813)、既存text128。入力bytesと乱数式は原版そのまま。
- frame prefix/type/bounds：short_header、old_magic(KHQCID01)、追加old_float_magic(KHQCFP01)、bad_magic、input_length、primary_field、alphabet_zero、alphabet_over、payload_short、payload_quota、payload_derived_bound。旧float magicは新magicへ自動移行せず `bad frame magic/header` 拒否。
- CRC/metadata：header_crc、payload_crc、plain_crc、metadata_padding、metadata_sentinel、metadata_width、metadata_rank。原版の修復/forge技法と厳密な既存error文字列を維持し、目的外の先行CRC拒否に置き換えない。
- range coder：range_prefix、range_gap、range_truncated、range_trailing、range_termination。正規化/終端/trailingの拒否を個別に固定する。
- decoded grammar/inverse：sentinel_count、primary_sentinel、lf_cycle、active_early、active_remaining。scripted token/run_doneの原因果順とactive更新を変更しない。
- escape：escape_noncanonical、escape_fourbytes、escape_remaining。255tokenからのescape境界を原版どおり作る。
- depth：unsupported_depth9、unsupported_depth_max、depth_crc。depth拒否順を維持し、別途長さ36..39の短depth header4件は `bad frame magic/header` を期待する。

34 malformed は各 decode Err の正確なreasonを比較。14 normal は各 encode2/decode1、全plain14/全再frame14/typedProof14比較14。短depth header4件は独立census。旧 Model::rejection_checks の26件/26assertions/CAPexact1は今回呼ばず、関連JSON欄を除く。primitive/primary_audit/frame_auditの旧seed APIへ依存せず、fixtureはcfg(wire_audit)、codec module配下のsuper::*だけを使う。cfg無しのrunは `wire_audit required` 拒否。

## 変換allowlist

原e2e全文から許す変更は (1) 全frame_audit識別子をwire_auditへ、(2) forgedにold_float_magicの1armを追加、(3) namesに同名1件を追加、(4)旧rejection_checks呼出を削除しcensusを14/14/14/34へ、(5) JSONから旧model rejection/CAP censusを削除、(6) all-state比較表現を全plain/typedProof14/全再frame比較の表現へ置換。追加の数値式、forge入力、通常fixture、error期待値変更は禁止。全文仮想変換との一致・残差0を非実行で確認する。

## 実行・資源・判定の境界

ststのhappy/boundary/typeを選択。CRC/grammar/range rejectをRAMで作り、実disk枯渇/chaos/並行性を扱わない。新単体unit testは作らず先行standalone E2Eを用いる。親指示により第一段階compile/native/verifierは0、非書込rustfmt/ASTだけ。動的成功は未検証。

後段親実行はselfcheck CLI1とfixed CLI1を別stdoutに記録、compile1/native2。selfcheckの有限input/frame/plainはfixed入力前に全drop。fixed inputは一read/encode1/decode1、全2811006plainとtypedProof14 Eq、実frame<=483599、共通CRC/grammar、WS/private両160MiBを測る。旧teacher entropy/digest/frame長との数値同値を新hard-cutへ要求しない。screen480782Bは実wire成功の証拠ではない。

source300KiB/EXE1MiB/report256KiB/output8MiB/free5GiB、compile60s/native各120s。input/frame/plain/raw event disk copy0、Cargo target/PDB0。後段unused build/khc-causal-hard-cut-wire-20261004は親の実行準備で確認する。本段階は新source2件のみで生成処理なし。速度/portable wire/製品採用/総合7-Zip超えを宣言しない。Git/旧証拠/製品/version/API/x86/外部write/delete/追加委任なし。保存後READYで2file編集停止、残りは親の第二段階許可。
