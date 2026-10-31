# Hamilton選択の未採用候補

CTS内部診断とは別の読み取り調査。変更・実行・採用はしていない。

`quaternary-cts-depth/integer_cts.rs` のktとnormalize_q2はHamilton残余の選択にprefix最大4要素のsortを使う。left==0なら選択不要、left==1なら余りの最大要素をchild昇順で走査しstrict `>`で更新すると同値tieの最小childを保つ。left>=2では既存sortを残す候補がある。

全前置guard、checked increment、最終sum/vector検査、エラー順を維持する必要がある。認証・CTSモデル・圧縮仕様の変更ではない。

反証: generic短配列sortは既に最適化され得る。追加branchが悪化要因になり、left分布も未測定。除算やKernel構築の方が支配的かもしれない。一律の固定4要素networkはleft0と短prefixにも余計な比較を課す。数値同値性だけでは採用しない。

KTの机上算術例（Q=2^32、k=4）: raw `[0,0,0,0]`でleft0、`[0,0,0,4]`でleft1、`[0,0,0,1]`でleft2、`[0,0,3,5]`でleft3。これはnative実行の観測ではない。

次の判断は内部診断後。候補を試す場合は別の事前失敗計画・出力root・直接契約比較と固定両方向ゲートが必要。同条件で不採用候補を好結果まで繰り返さない。
