# 実装前の失敗・独立検証計画

対象は浮動小数の機会診断のみ。圧縮wire・実サイズ・速度・製品の成功を判定しない。

- topologyの端点、空child、preorder ID、limit切詰め、単一合法child、256/257 alphabetの境界を誤り得る。各alphabetの全limit/全合法tokenを別の区間再帰oracleと照合し、枝からtokenを逆構成する。prefix 0/5、limit 0/A+1、token=limitを拒否する。
- known rankContextのcomponent/key/rowを誤り得る。rank 0、length 0/8、invalid 9およびrank非0を検査し、global 4608rows・nodeID<256を確認する。
- query後更新、合法prefix条件付け、half-count、rescale、posterior/share、collision rowを誤り得る。別のcount/weight配列と別式の分母・混合・posterior更新を全観測枝で逐次照合し、初期/強制rescale/invalid prefixと終端全stateも照合する。digestだけで正確性を主張しない。
- active vectorのnext-use順位、current symbol、previous/recent更新時点を誤り得る。別symbol出現位置配列とcursorからnextを得て、currentの次出現より早い別symbol数を数えるoracleを全889227runで照合する。両系のcanonical component/key/token/limit digestを保持する。rank/length中は同一のrun完了前stateを使い、独立historyとも毎run照合する。
- input/BWT/run/escape/full proof/old loss比較がずれると診断無効。固定SHA・readlock・一回read/BWT・件数/primary/escapeの照合とold flat intervalの独立prefix検算を行う。
- NaN/inf/zero/重み和、loss集計の漂流を拒否する。component別Kahan和と全体を比較し、全expert lossとcold件数/branch数/depth/rescaleを有界JSONへ保存する。
- compiler/runtime/import/proof/sourceの変更、未知import、子timeout/大量出力、fresh root再利用、EXE/PDB/容量上限を拒否する。pin/parser/import実在/preflightを先行し、親の確認後にopt2/overflowyesを一度compile/runする。未知失敗は最小証拠を保存して親へ返し、同条件retryしない。

生成物はfresh build/khc-quaternary-context-opportunity-20261002内のEXEと512KiB以下JSONのみ。8MiB guardは事前事後確認で強制書込みquotaではない。予想300KiB以下、EXE予約1MiB。frame/restore/rawtrace/Cargo/PDB/cacheは生成しない。

projected entropy + escape 5936bits < (483599-281-5)*8だけを機会gateとする。未達ならfull/benchmark禁止。達成でも整数化、range丸め、full/実サイズ/速度は未検証。
