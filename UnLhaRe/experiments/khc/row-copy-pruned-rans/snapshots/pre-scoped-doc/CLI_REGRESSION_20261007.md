# 実CLI＋既存KHC E2Eの実装前条件

2026-10-07 JST。native-a公開API E2E成功、newrlib BF50A95F66645A60156F89C8C8833D7D65DCA0448E3F15A1731BA4176303DC30を再利用。CLI help commentだけの変更を記録し、library sourceは成功時pinと厳密一致を要求する。
同じrelease flags・既存dependenciesで実CLIをstandalone compile、record-trial create/list/test/extractの全byte、help option表示、default旧revision1/2を検証する。さらに既存7ファイルWindows9 E2Eを新native rlibへリンクして実行する。新unit testは追加しない。既存fixed3blockは元groupをPinして再利用、corpus複製なし。
既存E2EのCARGO_MANIFEST_DIRを専用fixture-manifestへ設定し、既存sourceを変更せず生成先を今回のroot内に封じる。CLI version1.0.4、source/deps/proof/executable pinsを保存する。全helper envをfinallyで戻す。
失敗先行：compile/依存一意性/source drift、CLI不正strategyとhelp、作成先既存/展開先既存、frame/revision3表示、全byte復元、既存9テストの失敗/欠落、固定block未提供、timeout・RAM・disk overrun。終了時stdoutと各既存result.jsonを保存し、sourceとartifact hashを照合する。
新専用rootはcompiler一時物/CLI/test EXE/fixture込み最大24MiB、fixture最大8MiB、free>=5GiB+24MiB、Cargo増分0。compiler512MiB/60s、検証child64MiB/60s、suite300s、CPU quiet15%/60s。旧native root/EXE/rlibや共有cacheを上書きしない。新出力やfixtureを勝手に直接削除しない。速度証拠とは扱わない。macOS/ARM64・全面clippy/Release bundleは未実行のまま区別する。
