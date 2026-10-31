# Q32商の64/32整数経路 — 次の反証候補、未実装

## 今回の選択根拠

実書庫の診断ではKT129584506回中等カウント1680505（1.296841%）、posterior121961888回中半重みidentity4406596（3.613093%）だった。これを所要時間の上限や改善率に変換しないが、少数条件の分岐を増やす前に、通常の商処理の広い範囲に適用できる厳密経路を反証する。既存next_weightは既にshift32のため書換えない。

## 整数条件と例外安全

Q=2^32、既存checked product n=a*b、1<=d<Qとする。n=high*Q+lowで0<=low<Q。high<dならn<d*Q、従ってfloor(n/d)<Q。逆にhigh>=dなら商>=Q。この判定で商がu32に収まることを検査できる。

x86_64のDIV r/m32はEDX:EAXの64bit被除数を32bit除数で割り、32bit商と残余を返す。除数0又は商overflowは#DEなので、Rust側でd!=0/d<Q/high<dを検査してからのみ実行する。memory/stackへ触れず、flags保存を仮定しない。通常の64bit除算より速いことはこの仕様からは分からず、実速度の未検証仮説である。

現在helperのd==0拒否→checked product→d==Q shift→d>Q portable fallbackの順を保持し、その後にx86_64限定のguarded32経路を追加する案。非x86_64とhigh>=dは旧float推定・checked整数残余証明/補正・native fallbackをそのまま残す。private arbitrary u64の受理範囲、error優先、商値を変えない。診断flagsに新しい経路識別が必要なら新仕様として扱い、旧flagsとの全byte一致を主張しない。

有効KTは(2zero+1)<2(total+1)だから商<Q。実Treeのweightは初期Q/2、更新後もalpha>=1により<Q。child確率>=1なので実observed ceilingの分母はweight*pk/Qより厳密に大きく、posterior<Q。alphaもafter>=1でQ/2以下。これは通常Treeの範囲内の証明であり、任意helper呼出しへ外挿しない。新候補で実Model oracleも照合する。

## コード前の失敗条件

- 原helper D969F4CDD89A41BA70BD1BD4C3EC4F4D99004455C9B6C66B53DE4DCC470C0966、数値仕様・既存fallback又はerror順を変更する。
- high>=d/除数0/d>=Qで32bit DIVへ到達する。入力/出力/flags/汎用レジスタを誤宣言する。CPU設定やISA環境を変更する。
- Q-1/Q/Q+1、d-1/d/d+1のhigh、最大u64、商Q境界、積overflow、除数0とのerror優先、余り0/d-1、opt2/3、portable参照のいずれかがBigInteger oracleと不一致。
- 数値CLIの入力/record上限・完全record・no-clobber・祖先reparse・失敗時未公開・120秒制限を省く、再現raw/source/EXE/proofを保存しない。
- 数値成功や静的DIV命令を速度採用にする。旧全frame/相互復号と通常同session比較を省く。fixed size<=483599B/encode<574.5624msを緩める。
- x86_64の正確性・速度をARM64/macOSネイティブ実測の代わりにする。通常Rust/製品API/版/x86互換版を変更する。

次工程は新numeric-only directory native32-quotientで独立BigInteger・異常境界・opt2/3・強制portable参照をE2E検証する準備。CTS/codecへの組込みは数値/実命令結果の後で別条件を保存する。既存balanced候補は正確性freezeを保持し、CPU拒否で未測定のまま採用しない。各研究経路の基準と全体最良は区別し、BWTの局所改善を既存LZ系より優れるという根拠にしない。

一次資料: [Intel DIV instruction reference](https://www.intel.com/content/dam/www/public/us/en/documents/manuals/64-ia-32-architectures-software-developer-vol-2a-manual.pdf)（DIV/32bit operandの意味と#DE）、[Rust inline assembly](https://doc.rust-lang.org/stable/rust-by-example/unsafe/asm.html)（register operands/options）。この資料は候補の速度やKHC優位性を証明しない。
