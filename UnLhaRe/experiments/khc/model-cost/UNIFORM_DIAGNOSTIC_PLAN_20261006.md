# 次の費用診断：整数の均等分布

2026-10-06。前のlog単独ablationは通常順3.24%改善・独立逆順0.87%改善で事前両回2%条件を満たさず不採用。再試行で良い数字を選ばない。現在の量子化の呼出し総数、zero-count経路、leaf_mode、floor_codeを現在sourceから数え、次の問いを変える。均等CDFをHamilton法で毎回再構成する費用があるかを調べるが、LLVMの共通化や軽い処理なら性能効果はないので採用を前提にしない。

mod/model派生は13pathとPROFILE markerだけを追加し、除くと現本線に一致することをrunnerで確認する。paid_model/packet/decoder/形式を変更しない。カウンタはthread-local、各13入力warm1+9でframe全byte/自己復号/method/全4回数安定。raw/frame RAMのみ。量子化/leafのguard順も同一。診断時間はカウンタ自身の費用を含むので性能優位の証拠ではない。

専用8MiB/free5GiB、compiler512MiB/child64MiB、child60秒/suite300秒、quiet15%/60秒、report128KiB。EXE約1.1MiB/PDB約1.4MiB/link一時4MiB、Cargo0/download0。新unit・公開API/バージョン/Git/外部/他版変更なし。計測後、成立する場合だけcanonical整数CDFの再利用を別の単独ablationで検証する。全count0/全k2..4の元のHamilton結果、範囲外拒否、全frameと未見/7-Zip固定ゲートを維持する。現在は実験診断だけでGOALを完了扱いにしない。
