# rank/length root共同区間の有限成立性診断

2026-10-06。現MDL token/run約65%・inverse約27%、LZ二値閾値は6.7%に留まり不採用。次は逐次区間数の削減を読む。既存same-class compoundは2rootではなく隣接同classの2区間で、削減coverage7.08%が20%条件未達だった。その再調整はしない。

問いはrank root（class0/node0）とlength root（class3/node0）。両root prefixのlimitはrun開始時のactive_lenとremainingから得られ、historyは別class。rank rootの残りclass1/2とlength rootの残りclass4/5により独立に先読みできるかをコードと有限traceで検査する。ただし現wireのinterval順を変更する実装は同wire最適化と称さず、採用試作には別識別/versionを必要とする。

失敗先行:

- rootを動かしてclass history更新順が変わる、prefix/k1を含む進捗・alphabet/sentinel拒否が失われるなら不成立。
- joint productの最小support・整数roundingが0/1頻度を作る、CDF総和が32768でない、range unitが0になるなら不成立。totalを2^30へ無条件に増やさない。
- 16項product/quantizeを毎run計算する費用や、事前共有モデル/table容量を隠さない。簡単な独立productだけで圧縮率向上を仮定しない。
- 入力依存joint表は64MiB codec全費へ課金する。root frequencyのdistinct数の積が大きい時に無制限Cartesian tableを作らない。有限診断はraw trace0・frameごとのdistinct/適格数/counterのみ。

初回diagnosticは現在のdecodeにroot開始時のCDF（rank/length各2..4）のmin/unique pair censusを追加する別namespace。計装を除いた現mod/packetとの正規化一致、現公開/診断の全11保存frame完全復元、旧branches/runs/stats一致を実行してからcounterを信用する。逐次CDF productで保持できる最小support（各product>=2*32768）、k1除外、適格root pair数と削減可能区間数を測る。各単CDFのdistinct数とCartesian precompute見積も併記し、収集だけで速度優位を宣言しない。

screenは現8MDL branch合計に対して20%以上の符号区間を減らせること、joint表見積<=128KiB（最大4096行×16×u16、mapping等別費も64MiBへ含める）。不足なら別のquantization sweepやcorpus選別をせず、この構成を棄却。成立後だけ、全費用が分かる別wireの小試作・最小support/終端/誤入力・公開統合・強solid7Zip比較へ進む。

8MiB専用生成root/free5GiB、Cargo6169422158B固定/cap6175228536B/書込0、単体compiler512MiB/codec64MiB、child60秒/suite300秒、CPUquiet15%/60秒を維持。元GOAL5%rate+encode/decode不劣または率不劣/各10%速度、真正未見/総費用等を置換しない。これは次の未実行診断であり候補採用や完成証拠ではない。
