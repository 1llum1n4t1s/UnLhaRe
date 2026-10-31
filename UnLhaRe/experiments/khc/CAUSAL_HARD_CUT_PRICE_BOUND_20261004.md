# 固定Q8 cut価格の式と範囲

QUESTION SHAFA4803158022EF3F663BD5926F8D4CBED95BD4DD026D7A1E9F6EE48EEB247CC7の選択規則の算術確認。実predictor/codec/速度の成功ではない。

positive xについてexp=floor(log2 x)、indexを14bit整数部へshiftして16384..32767とする。凍結PRICES(false)でこのindexの価格は256-floor((index-16384)*256/16384)。したがってlog_Q8(x)はexp*256+floor((index-16384)*256/16384)となる。有限oracleはこの別式を直接用い、engineは既存bit_price(index,false)を呼ぶ。二乗で生成するprecise価格は使わず、既存一次近似と固定する。

指数区間内ではindexが単調非減少。指数境界の直前は最大exp*256+255、直後は(exp+1)*256なので全positive整数domainで単調。num=2*raw[child]+1、den=2*sum(raw[..k])+kは1<=num<=denであり価格log_Q8(den)-log_Q8(num)は非負。k1ではnum=denで価格0。xが2の冪なら価格は正確な整数bit×256。

CAP3825340よりden<=7650684<2^23、1event Q8価格<23*256=5888。ownの保守上限は22523601920、4子和＋penalty256の保守上限は90094407936。u32では不足するがu64内。通常rawはclassCAPで制約されるため、合法stateでu64 overflowは発生しない。人工stateのMAX値はpreflight拒否/whole state不変を検証するためだけ。

一次近似は真のlog2ではなく、累積近似誤差や同点が選ばれるcutを変える。実CDF損失との一致条件に使わず、モデル選択score/終端best/実hard選択lossを別々に報告する。精度やpenaltyの事後変更は別候補となり、この一構成screenの再試行にはしない。
