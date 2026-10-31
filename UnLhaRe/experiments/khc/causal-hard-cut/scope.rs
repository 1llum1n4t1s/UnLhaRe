//! 原Modelを直接参照。新primary型だけをaliasし数値式は変更しない。
use crate::{float_math as fixed_math,float_pool as integer_pool,engine as integer_cts,Result};
#[path="../lookup-float-cts/model.rs"] pub(crate) mod model;
