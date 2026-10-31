# node/history情報量診断の判定範囲（コード実行前の補足）

別新文脈のread-only analystから、empirical `sum n_i log2(N/n_i)` が同じkey・同じsupportのSTATIC CDF product-log-lossの最小であること、ただし任意の有限coderが出す個別frameの整数byte下界ではないことを受領した。有限符号の一入力codewordがlog-lossより短い場合、f64のceil/丸め、別のframing/side設計を含めて普遍的排除は主張できない。

QUESTIONの「主経路を閉じる」は、この固定情報量screenを研究予算の採否に使う意味に限定し、PLANの「このsuffix/node分布で保存費用を払う主経路は支持しない」へ揃える。ideal lossが大幅に超過すればSTATIC CDFへの追加工数を支持しない根拠となるが、全圧縮方式・実frame・適応分布の不可能性の証明ではない。`ceil(loss/8)+3079` はside費用を固定した診断予算、実wire仕様や厳密数学的byte lowerboundではない。PLANの1B境界は注意flagに限り、差にかかわらずf64診断は厳密下界へ昇格しない。厳密な排除には数値誤差の保証範囲と実coderの有限長下限が別途必要である。

depth5 full-historyはcoarser suffix partitionを精細化するためempirical log-lossは増えない。一方Q Hamiltonのlossにはこの単調性を仮定せず、static histogramに時間適応やblock別分布・別feature・学習更新がないことを明記する。prefix1の更新順/Front符号候補は元grammarに固定する。現在childをkeyに混ぜない。

これを次のrunner/report/RESULT採否へ適用する。parent PLAN/QUESTIONの保存SHAとコード・depth・Q・fixed total goalは変更せず、この補足をbefore/after pinする。現工程は実codec/frame/decode/speed/holdout未実施で、いかなるscreen通過も7-Zip総合勝利の証拠へ置換しない。
