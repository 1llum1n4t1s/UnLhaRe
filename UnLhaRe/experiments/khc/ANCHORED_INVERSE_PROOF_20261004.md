# 8-anchor構造：独立証明と実反証

2026-10-04。独立analystがQUESTION、permutation-inverse/packed.rs、causal-bayes-sais/bwt.rs、packed-inverse/contract.rsを全読し、QUESTIONのSHAも一致と確認。親はLF構築、forward BWTとcontractを確認し、小さいPowerShell計算で下記反例を実確認した。Rust/native候補の実行はまだ0。

## 成立する証明

LFがn行の置換、d_i=i*q、各区間長ℓ_iが最初7本q/最後q+n%8、anchor0=primary、LF^ℓ_i(anchor_i)=anchor_(i+1)（最後primary）とする。帰納的にanchor_i=LF^d_i(primary)で、全区間はprimary起点の長さnの単一walkへ連結する。n行後にprimaryへ戻り、途中global step>0でprimaryへ戻らないことを各load/write前に検査する。

もし途中0<=a<b<nで同じrowなら、置換の逆写像をa回適用してLF^(b-a)(primary)=primaryとなり、早期primary再訪禁止に矛盾する。よってn行は相異なり全行を一度訪問する。visited配列省略の正当化であってCPU高速化の証明ではない。

forward BWTはtext=input+1の末尾に唯一0を置き、SA[primary]=0、last[row]=text[(SA[row]+n-1)%n]とする。同じsymbolの安定rankでSA[LF(row)]=(SA[row]+n-1)%n、ゆえにSA[anchor_i]=(n-i*q)%n。SA-IS実装全域の無欠陥証明と混同せず、tiny独立suffix-sort oracleで実検証する。

## global早期primary検査を省けない実反例

lastは長さ72の全1からindex7だけ0へ変更、primary7、alphabet[0,1]。LFは7→0→1→…→6→7の8cycle、残り64行は固定点。

親のPowerShellでcounts/starts/occurrenceからLFを実構築、72stepを歩いた結果：

- q=9、anchors=[7,0,1,2,3,4,5,6]、unique anchors8。
- 全8segment終端は次anchor（最後primary）と一致。
- 訪問した異なるrowは8だけ、論理walkの初回primary復帰step8。

anchorの相違と終端検査だけでは誤受理する。interleave実装では、論理順とは異なりlane7/local1/global64等で先に不正primaryを検出し得る。fixtureはErrを要求し、最初の拒否indexが8であることまでは固定しない。各laneのglobal offsetで検査することが重要。

metadata32Bと生成LF walkの時間は実計上する。新6filesの実装はworker一人へ委任、先行FAILURE→source→停止READY、親全文確認→compile1/native1の順。現在は実装中で、速度/資源/完成書庫/4native/7-Zip超えは未検証。GOAL active、停止なし。
