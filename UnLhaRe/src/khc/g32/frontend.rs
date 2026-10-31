use super::bwt;
use crate::khc::block::frontend::Front as SharedFront;
use std::ops::Deref;

/// G32のアンカーを保持し、run形成と文法走査は旧形式と共有する。
pub struct Front {
    shared: SharedFront,
    pub anchors: Option<[u32; 32]>,
}
impl Front {
    pub fn new(plain: &[u8]) -> Result<Self, String> {
        if plain.len() > 8 * 1024 * 1024 {
            return Err("frontend input bound".into());
        }
        let (last, primary, anchors) = bwt::bwt(plain)?;
        Ok(Self {
            shared: SharedFront::from_transformed(&last, primary)?,
            anchors,
        })
    }
}
impl Deref for Front {
    type Target = SharedFront;

    fn deref(&self) -> &Self::Target {
        &self.shared
    }
}
