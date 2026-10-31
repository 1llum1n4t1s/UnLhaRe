# 検査済みraw Forestの不変条件を利用する局所改善

2026-10-07。変更前KHT1 E2Eは全11+4入力完全復元、partition1585176/backend524979/malformed350585を通過。全費用456940B。ただしpaired9/warm1通常60.5116→129.6790ms、逆順59.6204→129.4369msで不合格。
E2E report SHA316C64BC9F6289F617D239E9DF4BD457DC0E87FBA6C94E30C9BAE6D3DB97FAFE、speed report SHA6FF160E695B168D72EBFBE408AF0BA027662BAA1ADBD6021744F7670F40379AA。速度未達を成功に読み替えずdefault/nativeは不変更。

## 事前に確認した根拠と変更範囲

packet.rs Forestはprivate fieldsで成功したparseだけが生成するraw型。paid_model.rs parse_nodeは全4子を深さ5まで再帰し、全履歴へ代入する前にvalid_frequencyでf>=2/合計32768/tail0を検査する。defaultもuniform→model.rs quantize→valid_frequencyを通る。読み取り専用の独立調査と親の原典照合で確認済み。into_decodeは異なる型になりraw Forestへ戻せない。

この限定経路のtoken頻度の再検査だけを除き、k1合成row、component/node/prefix/history/slot/window/geometry/進捗/CRCは保持する。浮動小数点やunsafeを使わずCDF・識別子・モデル・履歴は変えない。仮説は冗長検査の実行費用削減であり、支配的原因だと断定しない。

非MDL入力は事前にKHC1BLK/rev1,2/method0,2,3/最大1MiB+40B/宣言raw一致へ限定し、native12MiB予約とcaller slicesを呼出前に課金する。KRS1や別形式の暗黙受理はprivate試作APIから除く。製品APIは変更しない。

## 失敗先行と固定条件

不正magic/revision/method/短いheader/最大サイズ超過/declared raw不一致/flags/reserved/CRC/末尾/KRS1入力、エラー後の正常呼出、全leaf両端/history差、完全復元、破損拒否を検証する。新unit testではなく既存の有限/E2E入口に追加する。サイズとeventsは前E2Eと照合するが、payloadの直接byte同一性は保存物がないので主張しない。

e2e-b合格後だけspeed-bを実行する。warm1/paired9/逆順、旧native decode以下、全費用<=457415B、encode<=1.10倍というゲートは維持。失敗ならこの局所改善だけで解決と扱わず、同じ実験を繰り返さない。source/docs/backups96KiB、各専用output8MiB、Cargo増分0、runtime64MiB/60s、compiler512MiB/60s、CPUquiet15%/60s、free5GiBを維持。ダウンロードや新データの保存なし。

バックアップ: 同ディレクトリpre-checked-forest-20261007.zip（token.rs/codec.rs/e2e.rs/PLAN）。復元は必要な該当ファイルだけをzipから戻す。現状は未採用・GOAL active。
