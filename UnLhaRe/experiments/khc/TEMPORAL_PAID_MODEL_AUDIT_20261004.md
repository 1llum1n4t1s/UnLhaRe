# 保存費用の読み取り調査と採否

独立analystは指定7資料と追加2資料（branch-history-mdl/model.rs、temporal-node-information/e2e.rs）だけを確認した。編集・compile/native・Git・外部操作なし。

## 反証と一候補

旧モデルはroot3本の最小leaf費用16+31+46=93bits、byte ceil12B、個別u32長4B。旧class2/5の278モデル×14tileだけで62272B、全284nodeなら63616B。無料screen452387Bの残枠31212Bを超える。この旧方式反復を主経路に採らない。全形式の一般下界ではない。

固定順component/node/kの852rootをtile packetにする。各root1bit default/explicit、defaultは原Hamiltonのquantize([0;4],k)。空rootまたはFitの無分割rootのCDFがdefaultと完全一致した時だけ省略し、原Fit予測・損失を保つ。explicitは原depth5木/splitbit/15bit frequency。tileごとu32有効bitsとpadding一回。

全default最低1554B。実header費M=sum_tile(4+ceil((852+explicit木bits)/8))。実診断条件はceil(Lparsed/8)+M+3079<=483599、または無料Qtoken449308からの増分+M<=31212。raw-bit DPはpacket全体padding込み最適ではない。最大packet payload5052999B、field付き5053003B。

## 限界と検証条件

無料情報gainはin-sampleの180526active/78971pure/354913nonzero行の保存費を払っていない。従来selectedモデルでも剪定増分10773B＋保存10577Bでgateを外した。新root省略でも非uniform多数なら棄却される。header最低値だけで成功を予測しない。

Dense1個・node scratch・tile packet1個を逐次保持し、全CDFは逐次直接比較する。全14tile11928roots/12214272CDF、旧Fit/quantizeと数値を変えない。packet連結のbit/CDF直接比較、完全packet parseとDense weighted loss、全Meta・全件数・資源を検査する。default k3の丸めを独立算術で検証し、既存空row loss0のoracleだけでdefault CDFを確認したとは呼ばない。

親は診断候補として採り、先行PLAN1FA09B573D7E2DA132CA5DEBF7FCCB0911D16AA05F2C77270E1D1BE7FAEB3C6Dを保存、workerに6filesだけを委任した。opopのPerformance/Hardening/Testerは独立調査、Normalizerは原数値と直接参照、Cleanerは巨大trace/全tileforest不保持、Modernizerは固定runtime維持、Asyncは逐次scratch解放とsource pins finally。Intel/Startup非該当。worker要求/実効は役割定義worker/gpt-6.1-sol/medium、fork none、追加委任なし。実行と最終採否は親が所有する。

実screen・RAM・CDF/Meta/loss不一致・source/EXE/report予算で判定する。サイズscreen成功でも実frame/decoder/速度/quiet/holdout/native4は別工程、全GOAL active/未達。製品/Git/version/依存/x86/外部/削除なし。
