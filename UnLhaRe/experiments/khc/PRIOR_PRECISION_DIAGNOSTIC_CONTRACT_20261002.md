# 正規化priorのcold/hot状態診断: 実行前契約

normalized full frame610222byte、旧direct575791byteより34431byte増で不採用。両full E2Eは正確性成功、正式性能は未実行。次のモデル選択前に、globalを正規化したP256に各token1を加えるCDFがcold keyで大きな一様支持質量を持つことを、小さい再現状態で確認する。これは全書庫size悪化の全原因や実寄与割合を立証する診断ではない。

old/new actual ContextModelを使う。alphabet256、key2、key0/token0を8192回更新する。root countsはtoken0=8193/他255個1、total8448。key0 local0=8192、key1全部0。audit count全値を独立expectedへ比較する。key1 cold token0 old(c,f,t)=(0,8193,8448)、new=(0,249,512)。key0 hot old=(0,40961,41216)、new=(0,33017,33280)。全symbol intervalを別の生配列/通常u128 prefix除算のoracleへ比較し、CDF支持とtotal一致、new cold全total=512/global正規化256+uniform256を確認する。期末countとquery拒否後の保持も確認する。

fresh `build/khc-prior-precision-diagnostic-20261002`、8MiB予算、opt2/overflow yesの1小EXE+小JSONだけ、予想200KiB以下。4条件や4native/性能/全面寄与を主張しない。source親所有 `direct-token-prior/precision_probe.rs`/`verify-precision.ps1` のみ、新old primitive source/reportは編集しない。source/import/contract/guard/compiler/runtime識別・readlock・beforeafter、120秒/65536文字/report512KiB、/DEBUG:NONE/Cargo/PDB/rawtraceなし。compile/run一度、existing root上書き/同条件自動再試行なし。

oldCDF SHA2F8308785D64BD65004A09529F76CC69E98E9DDA781BFCFB86BC76ADB8139E53、newCDF C046AF706803795762A6D2B3522A9D8747B08EDDA511DF0D576724F30BFD6E5C、scale138A83296052C562E35493D51943B744D450818D99FA2C09D5D769B08EB3B928。Rust1.98.1 compiler CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC。不要な一時物を作らない。Git/version/公開/外部書込み/x86なし。goalは全サイズ/速度/holdout/native/製品を含むままactive。
