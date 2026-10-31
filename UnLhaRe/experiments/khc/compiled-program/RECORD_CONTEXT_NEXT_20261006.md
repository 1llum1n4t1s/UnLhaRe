# 次の方式仮説：空間/レコード文脈の直接bit符号化

2026-10-06 JST。原GOAL active、未実装/未測定。current Program+rANSは2.95%/全体0.91%にとどまり、entropyの置換だけを反復しない。次は既存BWT grammar/root小変更ではなく、binaryの構造予測を独立に調べる。

## ローカル反証と一次資料

DEVELOPMENT.mdの旧216B転置は3,339B節約してもencode速度失格。filter-prototype/RESULT_20261005.mdのplane8/delta1/delta8/combinedは現MDL前置きで全file悪化。旧汎用direct-context mixerもfaxが弱かった。これは直接の空間bit predictorを成立させた結果ではなく、同じ転置/差分/filter/backendの再演はしない。

作者一次資料 [Data Compression Explained](https://mattmahoney.net/dc/dce.html) を2026-10-06に本文確認（該当節の更新日不明）。ZPAQモデル説明はbinary faxの前行8bit・前々行2bitという文脈を記載する。§2.1.2の1728×2376、MSB-first、216B/rowは**Calgary PICの説明**であり、Canterbury ptt5と同一画像だとは扱わない。作者 [PAQ1 paper](https://mattmahoney.net/dc/paq1.pdf) の検索結果は固定長recordの位置文脈を含むことを示すが、全文確認はまだなので設計の定数決定に使わない。既知技術の独立実装/改良という位置付けで、世界初/最新方式と主張しない。第三者sourceの取得・移植・GPL依存導入なし。

## 実装前に確定すること

1. 頻繁なbyte lagを小さなprefixから推定し、保存したlagだけでdecoderが再現できる汎用recordモードとする。filename/固定corpus寸法/全入力の未来bitをpredictionに使わない。候補lag、sample範囲、tie規則、追加metadataを評価前に1構成へ固定する。旧転置の幅sweepを再開するものではない。
2. 現在byteの過去bitと前行/前々行の復元済bitから固定整数contextを組み、整数probability更新でbinary rangeを直接使う。未来の同一row bit、浮動小数点依存、外部辞書は禁止。BWTやLZ前置きfilterではない。
3. 空/小/任意byte/非倍数/row端/上限/切断/未知識別子/CRC/終端/過大lagを先に失敗条件として書く。新private識別子、長さ/lag/CRC/終端を含む実frameで全byte復元を要求。stored fallbackを保持。
4. 元11fileと既存方式を比較し、全frame＋header/model/selector/復元情報の料金を含める。情報量censusのみなら実圧縮サイズ・速度と呼ばない。特定faxだけの有利さを7-Zip総合優位と呼ばない。

まずは上記の固定設計と既往実装の差を照合して1案を選ぶ。実行予算は専用8MiB/free5GiB、codec64MiB、既存Cargo共有、新raw/traceなしを継承。真正未見を調整に使わず、原7-Zipの全費用・率/encode/decode/RAM条件を維持する。速度micro最適化や不採用rootモデル利得の合算へ戻らない。
