# 凍結cloneの書式検査範囲

修正後の初回 `correspondence-fix/report.json` SHA `0F361FD82B17D0F1CF7EFAAF560EAB459BFBA1EA440071565CA9637CBDD36338` はrustfmt checkで終了した。元balanced CTS/CLIから保持したaudit専用の書式（Node literal、末尾空行、symlink枝、println）がrustfmt標準に一致しない。Model実行0、compile0で、数学的不一致ではない。

今回の契約はCTSのhelper pathだけ変更、CLI byteexact保持である。凍結cloneを再formatして数学以外の差分を混ぜない。新helperはrustfmt check、cloneは全文対応検査と4つのnative compiler実行で検証する。cloneがrustfmt cleanとは主張しない。製品コードのfmt gateや速度gateは変更しない。

新verifierの書式検査対象を新helperだけへ限定し、別root `build/khc-q32-native32-model-20261001-inherited-format` で一度E2E実行する。既存失敗proofとsource/fixture pinを維持する。
