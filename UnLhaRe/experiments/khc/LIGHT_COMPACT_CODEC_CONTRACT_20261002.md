# Light compact pathのfull組込み: 実装前失敗計画

前turnは全1114112 mappingと131072状態イベントが4条件で一致しPROGRESS。今回は凍結node-u32 codecのlight呼出しだけを新モデルへ接続する。既存数値/状態証拠は再実行せず、SHAと内容・現在のsource/EXEを照合して再利用する。7-Zip総合超えは未達、旧terminal速度試行と確認待ちの初期化分離は変更しない。

1. binding違い: 元node-u32 codec/scheduler、heavy/KTは凍結SHAのまま。codecは全文不変、schedulerのheavy pathを元node-u32へ明示、light pathを新sourceへ明示し、cfg診断だけlight/outer Predictionのsizeを追加。全文対応JSONとsource/compilerのreadlock・前後SHAを要求する。
2. 数値証拠の取り違え: light proof SHA99330ECA76275BE5B4B55F1E663612764B4CB88E60A02A8E3FE843B32928109F、7 checks/9 CLI/15 identities、4summary各mapping1114112/state131072/72値、拒否・継続件数、Node8B・Prediction160→24B、fingerprint d47b3bd91aab06f7を照合。cfg選択traceを正式codecへ入れない。heavy node-u32 proof SHA9627A3391CDC5995ADF757D2432235F9078899F026B02239AAA829D88EA8DF04、55/94/550と現在の全identityも確認する。
3. full予測/学習差: native/scalar×overflow-check有無の4variant、7入力（empty/single/all_bytes/repeated/periodic/seeded_random/fixed）の全frame/stdout/復元を凍結integer候補と実byte比較。旧decoderで新frame、新decoderで旧frameの双方向を確認。固定complete frame483496B/SHA CF62CD2324B4CF889CDDDB25C9508C28E4BD4D24217B93BB7D4FF9318C3EAD12と上限483599Bは不変。
4. 診断cfgの差: 別counted codecで実heavy kernel使用とschedule・frame・復元を比較。Node12B/917497 nodes/論理11009964B、light Prediction24Bを取得。encode/decodeの全診断一致を要求する。通常EXEにcounterや選択TLSを入れず、layoutから総RSS/速度を推論しない。
5. 拒否/副作用差: 破損magic/header CRC/payload CRC/truncated/trailing、encode/decode no-clobber、missing inputを拒否し、出力なし/既存sentinel保持を確認。Limitsやstale/class拒否の既存範囲を保ち、未検証の製品API安全性まで拡張しない。
6. 検証器の変更: 元compact full verifier SHA27BCE6AF9C53E8103CF2F54763952C6493E840547655F6982352B12BF69E37BBから明示対応で派生。full比較・子process deadline120秒・byte比較・旧kernel数値証拠・拒否試験は維持し、新proof/source照合を追加。旧frame/拒否条件を新候補へ合わせて緩めない。
7. 容量: build/khc-light-compact-codec-20261002、fresh一回、予算32MiB（見込み24MiB程度）、空き5GiB+予算の前後guard。既存fixture/compiler/proofを再利用し、新Cargo target/cache/rawdump/PDBを作らない。失敗証拠を保持し、自動再試行・上書きはしない。今回の一時物のみ安全条件確認後に清掃。
8. 達成範囲: correctness検証の時間は正式性能値に使わない。固定574.5624ms未満、CPU15%以下、warmup1+測定9・single-thread・循環順などを維持。holdout/カテゴリ、同境界decode、四native決定性、製品/API組込みと安全性が残るならgoalはactive。

親だけが編集し、製品/x86/version/Git/公開・共有cache・他process/CPU設定を操作しない。環境、argv、全source/proof/output identityと実結果をbounded reportへ記録する。
