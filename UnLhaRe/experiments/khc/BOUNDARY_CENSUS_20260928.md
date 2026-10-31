# ファイル境界の圧縮サイズ差 — 2026-09-28

修復parserは実装していない。事前に固定した二つの関門は、推定フレームが 483,599 bytes 以下であることと、別ファイル時間の比で縮約した solid 圧縮が 746.931 ms（7-Zip の 574.5624 ms × 1.3）未満であることの両方である。サイズは通り、速度は通らなかった。Silesia は使っていない。

入力は `build/khc-current-source-native-solid-20260923-group/all.group`（2,811,006 bytes）。Beam / Standard / lazy LZ のトークンを各文法の Range 符号器で再生し、終端 payload 長をファイル境界で記録した。再生 payload は元のフレーム payload と一致し、三つのフレームは往復した。Beam は 483,130 bytes、Standard は 579,558 bytes、lazy LZ は 531,353 bytes。増分の合計は payload 483,090 / 579,518 / 531,313 bytes で、40 byte ヘッダーを足すとフレーム長になる。

Standard を Beam の代わりに使うと増える payload は次のとおり。

| 区間 | 平文 bytes | Beam 増分 | Standard − Beam | 別ファイル Beam 時間 |
| --- | ---: | ---: | ---: | ---: |
| manifest | 222 | 167 | +11 | — |
| alice29.txt | 152,089 | 48,962 | +4,043 | 46.0944 ms |
| asyoulik.txt | 125,179 | 43,293 | +4,504 | 35.5695 ms |
| cp.html | 24,603 | 7,523 | +717 | 7.1062 ms |
| fields.c | 11,150 | 2,808 | +245 | 2.9393 ms |
| grammar.lsp | 3,721 | 1,085 | +104 | 1.1093 ms |
| kennedy.xls | 1,029,744 | 43,556 | +27,628 | 280.6171 ms |
| lcet10.txt | 426,754 | 118,558 | +15,749 | 145.9446 ms |
| plrabn12.txt | 481,861 | 163,946 | +22,566 | 186.8197 ms |
| ptt5 | 513,216 | 41,311 | +17,490 | 136.0101 ms |
| sum | 38,240 | 10,332 | +3,192 | 9.0288 ms |
| xargs.1 | 4,227 | 1,549 | +179 | 1.2342 ms |

483,130 bytes から 483,599 bytes までの余裕は 469 bytes。この余裕に収まる時間削減が最大の組は `fields.c` と `xargs.1` だけで、payload は +424 bytes、推定フレームは 483,554 bytes。別ファイル Beam 時間の削減は 3.5807 ms。この比率を今回の solid Beam 989.4223 ms に掛けると 985.266 ms で、746.931 ms を超える。関門は不通過。

lazy LZ との差も大きいファイルでは数千 bytes（kennedy.xls +13,692、plrabn12.txt +13,418、lcet10.txt +9,897、ptt5 +4,804）あり、同じ 469 bytes の余裕では小さいファイルしか置き換えられない。

別ファイル時間は solid 時間そのものではなく、1 回だけの計測である。group の 1 回計測は Beam 989.4223 ms、Standard 443.5230 ms、lazy LZ 875.6996 ms。中央値でも 7-Zip 比較でもない。

```powershell
./build/cargo/x86_64-pc-windows-msvc/release/examples/khc_lab.exe boundary-census ./build/khc-current-source-native-solid-20260923-group/all.group --algorithm beam --beam-width 2 --beam-block 8192 --beam-model blended --beam-matches bt5 --dictionary-mib 64
```
