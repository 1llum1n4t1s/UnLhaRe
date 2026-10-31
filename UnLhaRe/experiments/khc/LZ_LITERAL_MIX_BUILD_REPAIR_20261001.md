# literal mixtureの試験ビルド設定修正

初回root `build/khc-lz-literal-mix-20261001` はsource correspondence2件とCLI fmtを通過した後、controlのrustc compileで停止。checks3/CLI3、圧縮実行0。共有profile/suffix-probeに存在するserde_jsonへの参照を最小CLIの--externへ渡していなかったことがstderr E0433で確認できた。依存の新規導入ではなく、既存Release cacheのserde_json rlibを両ビルドへ渡す。また元研究moduleの診断exportが最小CLIから未使用になるため、CLI moduleへのunused_imports許可を明示する（dead-code用のみ、計算変更なし）。

初回のreport/ownershipを保持し上書きしない。新root `build/khc-lz-literal-mix-20261001-dependency-repair`へ限定して修正後を実行する。これは実際に修正したbuild設定の再検証であり、CPU負荷で止まった性能比較の自動再試行ではない。algorithm/context/weight/size/速度条件は変更しない。現在のcontract/source/compiler/rlibを改めてpin/hold/afterで確認する。既定Cargo/LZ/API/version/Gitを変更しない。
