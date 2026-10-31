# 逆BWTの再調査と既失敗候補の除外

確認日2026-10-07。CPU条件待ちの間に一次資料とローカル証拠を照合した。新dependency/ダウンロード/外部code移植は行っていない。後述の別案も未実装・未測定。既存の単純two-hop候補を再試作しない判断材料である。

## ローカル実測

mdl-phase-currentの現native診断（report SHADB880495967DD2C52BE11588CD7130516215E44F116B0EE23A7062E6A30CF755）では8MDLのphase median合計45.2663msのうちentropy+active28.9180ms、forest free+inverse12.7503ms。これはgroup medianではなくfile別phase median合計であり、inverseだけの占有率とは断定しない。前者がまず本線である。

既存lf-two-step/RESULT_20261006.mdとcandidate_packed.rsを確認。u32 LFを構築後、u64 next1/next2/2byte表を追加し構築peak12nを課金した版は、全cycle契約362879 graphと73812 last-column、1MiB境界/全復元を通過。しかしwarm1＋通常9組でinverse median合計11.7433→11.9190ms、全体58.1902→58.4776ms。既定25% inverse/5%全体短縮を満たさず不採用。report SHAA324E310D78A2E623D9351726C648232F7D3039A5D9366D833FF08176E425D10。これを新案として重複実装・同条件再測定しない。

## 一次資料と区別

[libsais公式README](https://github.com/IlyaGrebnov/libsais)は、逆BWTを5n memoryのin-placeに調整し、bi-gram LF mappingで2symbolを同時復号すると説明する。これは作者の実装方針であり、現codecでの速度や安全性の実測ではない。[公式C実装](https://github.com/IlyaGrebnov/libsais/blob/master/src/libsais.c)ではunbwt mainがbyte alphabet²のu32 bucketと可変長u16 fastbitsを別途確保するので、「5n」だけを全費用として転用しない。一次資料の取得ページには2025-09-01 v2.10.4の記載があり、raw/GitHub取得内容の表示範囲にも差がある。masterを再現可能な実装pinとしては未採用。

[ライセンス](https://github.com/IlyaGrebnov/libsais/blob/master/LICENSE)はApache-2.0。既存原理の再実装・改良として扱い、世界初とは呼ばない。本文・Cコードの転載や依存追加はなし。導入するならlicense/NOTICEと必要な第三者表示、正式source revisionのpinが必要。

単純u64二歩表とは異なる、初期構築とtable費を含めたコンパクトbi-gram mappingは再調査の余地がある。ただし現在は設計仮説まで。現形式のu16 257symbol（一意0 sentinel＋raw byte+1）とlibsais byte APIのsentinel/header conventionは異なり、APIの単純置換はできない。cycleの完全検査、odd末尾、早期primary帰還、visited、rawCRCを維持する独立oracleが先に必要。任意不正BWTに対する拒否契約やRust safe版の費用は未確認。

次の順序は現在のcompiled-walk E2Eと固定decode gateの判定を先に回収すること。未測定候補をさらに増やすのではなく、この結果とentropy/active支配の証拠で実装の採否を決める。7-Zip総合優位・真の未見・Zstd・native統合の条件は維持。
