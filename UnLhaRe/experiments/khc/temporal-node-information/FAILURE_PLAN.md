# 固定14tile無料情報診断の先行失敗計画

この文書を実装より先に保存する。対象は private 診断のみ。製品、旧証拠、依存、version、Git、x86、外部、削除、runner、追加委任は変更しない。worker の compile/native は0。

## 失敗条件と先行有限E2E

- run は0起点、同runまたは直後のrunだけを許し、rank側のbranch群からlength側へ進む。逆行、欠落、run範囲外、rank/length順序異常、未完の終端を拒否する。
- 更新前run番号を65536で割る。run65535/65536、同run複数branch、rank/lengthで境界を分断しない。固定入力は13完全tile＋37259-run末尾＝14tile。境界ちょうどの終端に空tileを作らず、非空末尾を一度だけflushする。再finish、finish後recordを拒否する。
- component/node/class/prefix/childを検査する。prefix1はchild0だけ、coded rowには入れず履歴更新には入れる。class別のhistory10はtileでresetしない。跨境history不一致を拒否する。
- 全row/全childを固定サイズoracleと直接照合する。tailが非zero、CAP超過、shape破損、非有限または負のlossを拒否する。oracleは旧Denseのindex関数・quantize・loss集計を呼ばず、独立Hamilton算術とchild確率を使う。
- tile/component/node/wholeのcountとempirical/Qlossを突き合わせる。flush漏れ・二重・clear前後の混入を検出する。拒否後は同processで正常入力を完了させる。
- tiny byte入力を本物のFront::new→grammar::walk→集計へ通す。synthetic境界fixtureとは分けて報告する。RAM内fixtureは有限固定配列、全event traceを保存しない。

## 実入力契約と診断の限界

2811006B/SHA18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76をread1/BWT1/固定集計walk1。先行E2Eのtiny Front/BWT/walkは別カウント。全Meta（prefixes/final_historyを含む）と旧raw reportの直接比較は親runnerの責任。元の第二walk event Qloss再生は継承しない。

無料Qtoken ceil<=480520B、side3079Bを加えて<=483599Bだけを情報条件とする。保存モデル、frame、decoder、holdout、速度、7-Zip達成は検証せず主張しない。Qlossのpartition単調改善も主張しない。

## 資源・復元台帳候補

旧Dense1個の容量13959192B。14同時Denseは禁止。固定集計配列＋有界observerのみを足してmodel<=24MiB、fixed phase<=48MiB、BWT141598926B、native working set/private各<=160MiB。各flush872448 rows、実入力14flush＝12214272 rows。source closure＋PLAN＋本計画<=300KiB、将来EXE<=1MiB/report<=256KiB、EXE/reportだけ2files・8MiB、空き5GiB。新Cargo/PDB/ASM/frame/plain/rawtrace0。

grammar.rs は旧 node-history-information/grammar.rs の callback型 `FnMut(usize,usize,usize,usize,u16,usize)` の末尾に `,usize`、callback呼出 `histories[class],child)` の末尾に `,meta.runs` を追加するだけ。逆の2置換後の全文が原文に一致することを親runnerの復元ledger候補とする。履歴更新、prefix1、token grammar、Metaは一切変更しない。全5files保存後rustfmt stdoutによる非書込syntax確認のみを行いREADYで編集停止する。
