//! 既存7ファイル/Windows 9 E2Eの束ね。新unit testは追加しない。
#[path = "../../../tests/khc_normal.rs"]
mod normal;
#[path = "../../../tests/khc_adversarial.rs"]
mod adversarial;
#[path = "../../../tests/khc_block_normal.rs"]
mod block_normal;
#[path = "../../../tests/khc_block_adversarial.rs"]
mod block_adversarial;
#[path = "../../../tests/khc_model_boundary.rs"]
mod model_boundary;
#[path = "../../../tests/khc_hybrid.rs"]
mod hybrid;
#[path = "../../../tests/khc_state_safety.rs"]
mod state_safety;
