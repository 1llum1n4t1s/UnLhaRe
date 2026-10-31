# compiled decoder製品経路の実全書庫測定

2026-10-06 JST。試作namespaceの52%改善を製品性能へ転用しない。仮統合製品Release CLI SHA256 71EF1B98BC3CDF3477E39C6C4B823E10291A77DBA1590007F4667C687C266295を、既存11entry/2810784B書庫と7za26.03の強solid書庫で比較する。KHC466395B、7z481490Bを全費用とし、未見ではない開発データであると明記する。

7zはmx9/mfb273/md4m/mmt1、実LZMA2辞書3MiB・solid1block。辞書が全データを覆う。既存書庫・ツール・入力SHAを再照合し、現製品CLIのextractで全11入力をstream逐次byte比較する。抽出物は1回だけ、最大2810784B。性能はkhc-test対7za t（全復号+CRC、書込時間ではない）、warm1+9pairedを通常/逆順で各実行。同一EXE・書庫を両順でpin。全sampleを保持し外れ値を除かない。

旧製品の149.4961/149.2002msは過去の独立sessionであり、同時Before/Afterの証拠としない。現native短縮が15%以上なら試作改善の製品移行を支持するが、元GOAL固定ゲート（率5%優位+encode/decode不劣、または率不劣+encode/decode各10%優位）を置換しない。現3.135%率優位だけでは完了しない。encode再測定、真正未見、Zstd、4環境等も残る。

資源: output8MiB、report128KiB、free5GiB、codec/各child64MiB、child60秒、suite300秒、CPU quiet15%/最大60秒。Cargo shared cap6175228536B/出力追加0。sampling上限は全瞬間peak保証でない。測定に不要な新Cargo build/target-dir/ダウンロードなし。今回の抽出copyだけ許可済みcleanup窓口で清掃し、固定書庫/ソース/結果は保持する。

opop観点は前PORT/STATIC/NATIVE台帳を継承。親がPerformance/Tester/Async（owned process・pin locks）/Startup（表・EXE費）/Normalizer/Cleanerを担当。Modernizer/Intelは現依存・外部仕様変更なし。分析担当compiled_model_memory_audit（要求/役割実効gpt-6.1-sol/medium、readonly）はHardening/Testerの全可変モデル未検証を指摘し、親が既存E2E入口を拡張して実行済み。新unitなし、公開API/wire/version変更なし。
