# Multi-symbol range primitive 失敗計画

実装前に次の失敗を列挙する。検証は standalone CLI のみで、unit test は作らない。

- total 0 / 81921 / u32::MAX、frequency 0、cumulative+frequency overflow / total 超過を状態変更前に拒否し、その後の正常符号化を baseline と照合する。
- u128 scalar interval oracle で division rounding、low 更新、range 更新、byte normalization、carry と delayed 0xff を照合する。total 1 / 2 / 256 / 81920、first / last / full interval、skew と seeded stream を含める。
- decoder slot query は無変更。consume は slot が interval 外、rounding gap、入力不足を状態変更前に拒否し、その後の正常 consume を確認する。
- leading nonzero、5 byte 未満、truncation、trailing、terminal code nonzero を拒否する。source byte を readonly のまま照合する。
- hard output limit 0..4、exact length、one byte short、normalization 中の limit、delayed flush group の limit を確認する。拒否後も encoder state を保ち、許容 interval の再選択を確認する。
- constructor の初期 reserve を min(limit,1MiB) とし、growth を limit 以下へ抑え try_reserve_exact を使う。allocation failure の実注入は実施せず API の fallible 経路をコードで確認する。
- CLI encode の serialized hex stdout を別 CLI decode process に渡す。opt2/3 と overflow checks on/off の4条件で fingerprint、oracle counters、CLI 結果を一致させる。

生成先は fresh `build/khc-direct-token-range-20261002`、8MiB 上限、見込み1MiB以下。親の指示に従い4条件それぞれの EXE と bounded JSON 要約を保持し、同 root で再コンパイルしない。child は120秒、stdout/stderr各65536文字、PDB / Cargo target / cache / raw trace は作らない。compiler path/version/SHA、argv/CWD/source SHA、disk-budget 前後を report に残す。失敗時は同条件を無制限再試行しない。
