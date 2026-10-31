# 整数コード逆表の単独ablation

2026-10-06。現本線診断13入力/warm1+9成功、frame/method/回数安定、全130自己復元一致。report SHA42C52DAE94742F06CC7B0571BB3F9EB3AC5D8EBAF434F9D6DF0AA60E7341CA79、namespace正規化/pins true。8MDL入力の整数検索834578回、log2計算1594457回、Fit時間比約20.8〜50.6%（各入力medianの比、counter自身の影響あり）。旧工程比率を流用しない。

反証先行：全u16値65536の成功code/拒否文字列を旧新照合。正常範囲は2〜16383で、現MINOR_LUTの最後の<= indexを保持。範囲検査、quantization/CDF/leaf/Hist/writer/CRCを一切削除しない。追加表はコンパイル時static readonly16384B、動的確保/起動時初期化/外部依存なし。製品への採用はまだ行わない。baseline_modelは凍結比較用の小さなsourceで、バックアップや別の製品経路ではない。

製品modとの差は13pathとmodel公開（harnessのみ）。モデルとの差はFLOORマーカー内の逆表生成とfloor_codeの検索2行のみ。runnerは各差分を除くと現製品と同一か確認する。canonical表全256boundaryとその直前/後は全u16走査へ含む。

既存11development＋空/1B、全13入力。warm1+9pairedで交互に旧新encoderを呼ぶ。候補順反転・入力順反転の独立再現も実施。各frame全byte、method、自己復元/相互復元を逐次照合し、切断/再CRC変異112件（空96件）の旧新正常/エラー文字列も比較。試験namespaceのencoder時間はscreen専用で、公開APIでの実際の7-Zip優位ではない。2回とも合計median encoderが2%以上改善し、MDL入力ごとのmedian悪化5%以下、frame全一致、全guard成功なら次の公開API採用検証へ進む。固定GOALゲートは変更しない。

追加download0/Cargo0、専用work8MiB/free5GiB、compiler512MiB/child64MiB、child60秒/suite300秒、quiet15%/60秒、report128KiB。2namespace EXE約1.4MiB/PDB約2MiB/link一時4MiB。raw/frameはRAMのみ。独立逆順は固定初回EXEを再使用し、report/pin照合して複製しない。計算負荷が上限へ達したら、該当工程の記録を残して別の安全な問いへ移る。
