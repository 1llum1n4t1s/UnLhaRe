# 旧CTS/新suffixのclass別Q15 histogram診断

前工程で新suffix expertは正しく復元できたが、旧483469Bに対して488592B、gate483599Bに未達だった。構成を変更せず、符号量増加がrank/run grammarのどこに集中するかを診断する。閾値/depth/混合係数/symbol順の調整、性能/holdout測定ではない。

class対応は元codecのStream::rank/length/integerに従う: 0=next-use rank終端(rank==0)、1=rank==1、2=rank-1のunary exponent、3=rank-1のmantissa、4=run length==1、5=length-1のunary exponent、6=length-1のmantissa。primary/CTSまたはsuffix/Bayes mixtureの更新前zero予測から、rangeが受理した実bitのobserved Q15（bit0:p、bit1:32768-p）を記録する。range受理後・model学習前の診断hookだけであり、現在/未来bitで符号化予測を変更しない。

新source `suffix-class-entropy/{old.rs,new.rs,histogram.rs,verify.ps1}`だけを親が所有する。old/new wrapperは元全文からモデル参照を対応する凍結sourceへ向け、cfg gated histogram module/初期化/成功公開後のdumpとhookだけを追加する。source全文対応を実行前に検査する。shared numeric/BWT/primary/Bayes/rangeは変更しない。追加histogramは診断専用Mutex所有Vec<u64>（7×3×32768 bins、5505024B）。多thread codec、global model cache、単位テスト追加はない。モデル参照と診断除去後のwrapperが元sourceと対応し、実frame/復号が元と全byte一致しない診断は無効とする。

bin0は未使用。外部raw formatはASCII `KQHIST01` 8B＋LE u32 classes=7/components=3/bins=32768＋LE u64 counts、合計5505044B。primary/suffix/mixedの順。1processで1操作、mainで診断を初期化し、成功したframe/restore公開の後にoutput path＋`.q15hist`へCreateNew系の既存publishを用いて書く。開始時にframe/aux両既存出力を拒否する。2ファイルの同時atomic公開ではなく、aux公開失敗時はframeが残り得るためその試行を失敗として保持する。研究CLIのpath/publicationを製品のparent-handle安全性と混同しない。

失敗条件: 元/診断source correspondence、source/compiler/入力/pinsの差、cfgで確率や学習順が変わる、current bitがpredictへ流入する、5505044B format/unsigned counts/class bounds異常、bin0非zero、各class/component合計bit数不一致、旧新primary histogram不一致、encode反復/decode histogram不一致、元frame/restore全byte不一致、120秒timeout、no-clobber不一致、owned tmp/reparse残存。aux出力まで成功しなければdiagnostic成功にしない。

新root `build/khc-suffix-class-entropy-20261001`、既存拒否、自動retryなし。Rust1.98.1/edition2024/panicabort/opt3/native diagnostic EXE2個、旧/新それぞれ固定group2encode＋1decode、代表既存output/aux no-clobber。入力group2811006B SHA `18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76`。旧frame483469B SHA7584...、新488592B SHAF9B7...と全byte照合。class bit countsは元grammarの整数診断と同じ `[889227,888970,2472373,1835474,889227,426165,221182]`、合計7622618を照合する。

符号量推定は収集後に`-sum(count*log2(q/32768))`をclass/component別に算出する。整数histogramが再現証拠であり、f64のloss集計は近似診断値。range仕上げや丸めの費用を含む厳密な書庫byte帰属とは称さず、予測loss差を時間削減率に換算しない。固定developmentのみ・新作者独立監査なし・4native/holdout/製品/総合7-Zip超え未達。

補助担当への読み取り専用追加依頼はselected model at capacityで失敗したため再起動せず、親が直接調査する。以前の担当結果を新独立監査へ読み替えない。
