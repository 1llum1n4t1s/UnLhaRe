# 自己完結frameへ進むための実装契約

2026-10-05。全決定モデルscreenの次段階であり、以下は未実装の設計契約。screenが整数CDF一致・保存費用・資源上限を満たした1構成だけを進める。これを形式の完成仕様や性能実績と呼ばない。

## 既知技術と今回測る部分

SA-IS/BWT、next-use rank/run表現、文脈木MDL、整数range coder、CRC32は既知技術。今回の実装差分は、全6classの10bit履歴を保持した284モデル、モデルごとの履歴順選択に対する実bit課金、wire内の整数確率だけを使う復号、全費用込みのstored選択である。これらの組合せの優位を仮定せず、履歴順選択を外した比較を完成frameで測る。初期実装はscalar CPUのみを必須とする。

## 小規模frameと資源

製品の初期block上限は1MiBとする。現在の2811006B group screenはそのまま製品blockの成績へ流用せず、1MiB分割の実サイズ・時間を別途測る。原入力をblockごとに読み、符号化・復号の同時メモリを64MiB以内に制限する。並列block処理は初期実装に入れない。既存実験のCAPや8MiB上限を製品の無制限な保証へ変換しない。

Frontのrun列から最初に出現するsymbol順を保存する。復号はactive listの先頭からrankとrun lengthを取り出してlast列を構築し、LF置換のvisited検査付き逆BWTで元byteを返す。各branchではprefix k=1もclass履歴を更新する。k>1はpacketから復元した整数CDF総量32768を使う。符号器はfloat計算を使わず、encoderのMDL木選択結果だけをwireに入れる。長いrunのescapeは正準varintをuniform byte intervalとして符号化し、余剰・非最短表現・remaining超過を拒否する。

model packet最大約5MiBは作業用の保守的上限であり、全blockにその大きさのmodelを保存しない。最終圧縮bodyがstored body以上ならstoredへ切り替える。復号は長さ加算をcheckedで検査し、bodyを原長より大きくできない契約でallocationを限定する。小入力はstoredで正常に対応し、空入力にも意味のあるframeを返す。

## 識別とwire案

既存LHAと実験のKHC0LAB/KHQCHAは変更しない。新しいmagicとversionを使う。暫定候補は8byte magic `KHC1BLK\0`、version 1、method 0=stored / 1=全決定静的モデル、flags 0。最終仕様化時に識別子の衝突・読み書き両方を照合し、採用値を凍結する。製品manifestのversion更新とは別である。

| offset | 候補field | 契約 |
| --- | --- | --- |
| 0 | magic 8B | 別形式として識別 |
| 8 | revision u16 LE | 未知版拒否 |
| 10 | method u8 / flags u8 | 未知値拒否 |
| 12 | raw length u32 LE | 0..1MiB |
| 16 | primary u32 LE | compressedはraw+1未満、storedは0 |
| 20 | model length u32 LE | packet上限内、storedは0 |
| 24 | payload length u32 LE | 全body費用の上限検査 |
| 28 | alphabet length u16 LE / reserved u16 LE | storedは0、reserved=0 |
| 32 | plain CRC32 | 復号した全byteを検査 |
| 36 | wire CRC32 | 先頭36B＋全bodyを検査 |
| 40 | alphabet / model / payload | 合算が残りの全byteと一致 |

CRCは偶発破損検出であり認証・暗号ではない。compressed alphabetはsentinelを含む重複のない0..256の順列、modelは全284node/852rootの厳密packet、payloadは終端まで正準range streamとする。alphabetの具体的bit packingは実費を測ってから仕様へ確定する。

## コードより先に固定する失敗条件

- 正常: 空・1byte・全値・反復・skew・疑似乱数・既圧縮・block直前/一致/超過をbyteで直接往復照合。各normal caseのstored/compressed選択とframe総量を記録。
- 異常: unknown magic/revision/method/flags/reserved、header/body切断・余剰、加算overflow、原長/primary/alphabet/packet不正、range終端不正、CRC違反、LF複数cycleをpanicなしで拒否。
- 状態: 異常frameの後で正常frameが復号できる。復号は外部学習状態・浮動小数点モデル・辞書配布・ネットワークに依存しない。
- 資源: 1MiBを超える宣言を確保前に拒否。時間・容量・OSピークを測る。巨大raw/event/CDF出力は保存しない。

正常と異常の有限E2Eは別ファイルに置き、failure-first文書を先に保存する。frameの真の圧縮・展開成功後、独立Rust namespace/CLI、handle-relative nofollow/no-replace公開、複数ファイルcontainerへ統合する。順序はKHC_INTEGRATION_PLAN_20261005.mdに従う。完成codecと実API/CLI E2E、仕様、Zstandard/LZMA2比較が揃うまでGOALは未完了のまま継続する。
