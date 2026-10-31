# 17段を維持するQ16 CTSと48bit exact reciprocal

前段の6段間引きはsize NO-GOで閉じた。次はdepth16/17段/class7のdense contextをそのまま維持し、CTS内部の確率・重みをQ16（Q=65536）へ変える別形式の一構成を試す。最終range coderはもともとQ15で、内部1guard bitを使う仮説だが、累積丸めで圧縮率が落ち得る。旧Q32の数値/予測/frame同値を主張せず、失敗後にprecision/switch/depthをsweepしない。

KTはfloor((Q*zero+Q/2)/(zero+one+1))を1..Q-1へclamp。equal countsは検査後にQ/2。mixtureは元のfloor、観測側posteriorは元のceiling、leaf→root更新順・history16bit・観測cap562036803を保持する。switch alpha=max(1,floor(Q/(after+1)))で、観測65535以降にalphaが0へ消えることを防ぐ新仕様。最終Q15はround((Q16 probability)/2)を1..32767へclamp。これは単なる型短縮ではない。

Q16のKT小分母と全正常posteriorを共通の65537element u64 tableで計算する。A=2^48、d in1..=Q、r=ceil(A/d)。n<Q*dなら(n*r)>>48がfloor(n/d)に厳密一致し、u64積も収まる。n==Q*dは乗算前にQを返す。d==Qはchecked numerator>>16。d==0/checked product overflowを先に拒否し、範囲外は凍結native32 helper（そのQ=2^32は変更しない）へfallback。private arbitrary argsに正常snapshotのdomainを強制しない。

証明: e=d*r-A∈[0,d)、n=q*d+s。n*r/A=q+s/d+n*e/(d*A)、追加誤差<Q*d/A=d/2^32<=1/dなのでfloorを跨がない。最大積(Q*d-1)*r=Q*A+Q*e-r<2^64（Q*e<Q*d<=2^32<=r）。等号入力はn*r=2^64+Q*eとなるため乗算不能。正常posteriorはS=w*pk+(Q-w)*child、d=ceil(S/Q)なのでn=w*pk<=S<=Q*d。alpha∈[1,Q/2]なら更新weight∈[alpha,Q-alpha]、clampされたp∈[1,Q-1]から正常d∈[1,Q-1]。既存担当の追加読み取り検討でもこのdomainと等号/fallbackの必要性を確認したが、新独立作者監査ではない。

tableはModel1個に1個、524296B、构築をfullCLIに含める。Node16B/Prediction544B、17KT/16posterior/16mixtureそのものは維持。normal posteriorのinteger divideをtable lookup・64bit multiply・shiftで置換する構成であり、table/cache/guard/初期化/precision変更を含めた実速度は未証明。

light、Bayes、light gain64bit hysteresis、journal上限8388608record、causal replay、カウンタとprimary/BWT/grammar/rangeは通常schedulerから保持。全classes共通、新magic通常 `KHB16S01`、小journal `KHB16T01`、製品/default/API/version/x86は変更しない。全過去heavy Q16参照との比較は有限Q15比較であって旧Q32や全内部状態のoracleではない。

失敗を先に列挙: reciprocal/table/domain/equalityのoverflow、d0とproduct overflowの順序、table外fallback誤り、KT total overflow/cap/clamp/等カウント差、alpha0や範囲逸脱、source correspondence/pin差、current/future bit利用、重複/欠落学習、replay参照不一致、encode/decode/portable/schedule/frame/CRC差、旧/通常scheduler/小journalmagic受理、代表破損や既存出力の公開、source/input変化、120秒timeout、ownedtmp/reparse、固定size超過。

new unitなし。最初にstd-only numeric CLIで全d1..65536の境界・中間点、等号、範囲外、large/random u64、KTのcap/overflow等をu128 direct multiply/divide oracleと照合し、native/forcedportable recordsを全byte比較。これは新整数oracleで有限入力を照合するだけで、独立作者/全u64網羅ではない。そこを通過した場合だけ、通常codec native/forcedportable/連続Q16 heavy参照・小journal・代表7入力・固定反復・破損/no-clobber/magic拒否の有限CLI E2Eを行う。

新root `build/khc-q16-dense-cts-20261001`、CreateNew/既存拒否。Rust1.98.1 std-only/edition2024/opt3/panicabort。固定group2811006B SHA `18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76`、完全frame<=483599Bを先に判定。不合格は速度/holdout/設定sweepへ進まない。通過後の正式速度は別契約でquiet15%、single-thread fullCLI strict<574.5624msを維持。f64 primary/Bayesの四native決定性・同境界decode/資源・holdout/category・製品path/publication/cancel/metadataを含む総合goalはこのstageに縮小しない。
