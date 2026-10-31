# 過去lossによるheavy CTS停止・順次replayの一構成

[支持範囲](CAUSAL_EXPERT_SCHEDULING_FEASIBILITY_20261001.md)に基づき、親だけが`causal-expert-scheduling/`の新研究sourceを所有する。製品/default/API/version・元研究sourceは変更しない。新magic `KHBSCH01`。BWT/packed grammar/primary/rangeは保持し、expertをclass7すべてに同一規則で制御する。corpusやclass番号で事後固定routingしない。

lightは凍結adaptive-suffix-kt Model（depth16/count32）と凍結Bayesの組。heavyは凍結KT reciprocal CTSとBayesの組。Bayes cloneには更新前のprimary loss minus expert lossを返すgetterだけ追加し、既存数値式/表/学習を変更しない。現在bitを見る前、lightの累積gain>=64bitsならheavy active、<=-64bitsならinactive、その間は前mode。初期modeは全class inactive。このconfidence/hysteresisは一構成へ固定し、失敗後にsweepしない。

停止中は更新前primary Q15と実bitをrepr(C)4Bのrecordとしてclass別journalへ保存する。再開時は未処理recordだけを古い順でheavy CTS.predict→heavy Bayes.predict/update→heavy CTS.updateし、過去prefixのcounts/history/weights/alpha/累積lossを復元する。現在bitの予測前にreplayを終える。activeではheavyをその場で1回学習、lightは常に1回学習する。primaryは元の順で全eventに1回更新する。heavy processed + pending == observed、active observed + replayed == heavy processedをclassごとに維持する。

journalのlogical reserved records合計は8388608（record array32MiB）。初回capacity1024、以後2倍の固定growthとし、予測前に必要capacityが合計上限を超えるなら同classをforced activeにしてpendingをreplayし、journalを解放する。分岐は決定論的logical capacityで決め、allocatorが要求capacityと異なるcapacityを返した場合は試行を失敗にして別routingへ変えない。metadata/他models/BWT/allocator overheadを含むhard process memory capやpeak memoryの証明ではない。allocation失敗/世代不一致/無効class/probability/上限は失敗としてpoisonし、成功公開しない。

失敗を先に列挙する: source/correspondence/pinsの差、現bit/未来の選択利用、replay順/primary Q15/他class混入、event重複/欠落、heavy状態のprefix不一致、古いprediction/別class update、journal超過、allocator容量違い、f64gain非finite、encode/decode modeや件数差、frame/復号/CRC不一致、旧新magic混同、代表破損/既存output公開、120秒timeout、source/input変化、owned tmp/reparse残存。replay中のエラーでもその試行を失敗のまま保持する。

まずnative/forcedportable通常構成を、空/1byte/全byte/反復/周期/seeded random/固定groupのCLI E2Eで検証する。切替/active/replay/pendingの整数件数を成功stdoutに含め、各classの不変式とencode/decode・反復の一致を照合する。追加でjournal64recordsの診断cfg（別magic `KHBTST01`）を作り、forced catch-upと復号を周期入力で確認する。これは通常構成のサイズや速度の代用ではない。新unitは書かない。

replayの状態整合性は、診断cfgだけ、予測器を停止しない参照CTS/Bayesにも全eventを同時に学習させ、active/replay完了時の次のheavy予測とBayes Q15を照合する。参照を足した診断codecは通常frameと全byte一致が必須。有限の実行参照であり独立数値oracle/新独立作者監査/全状態網羅ではない。通常candidateにはこの常時参照を付けない。

新root `build/khc-causal-expert-scheduling-20261001`、既存拒否・自動retryなし。std-only Rust1.98.1/edition2024/panicabort/opt3。固定group2811006B SHA `18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76`、size<=483599Bを先に判定。不合格はこの一構成を閉じ、time/holdout/閾値sweepは行わない。通過時だけ別契約のsingle-thread fullCLI strict encode<574.5624ms、native7za11files solid/同session/warm1+9/quiet15%/peak memoryへ進む。

f64 gain/primary/混合の決定性は検証環境のみであり4native未保証。研究path/publicationは製品parent-handle安全性とは別。完成判定は固定groupだけでなくholdout/カテゴリ、同境界decode/資源、4native、製品を含む元の総合goalで行い、今回のstageを7-Zip超えへ縮小しない。
