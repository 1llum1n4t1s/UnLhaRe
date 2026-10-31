pub fn exponent(value: usize) -> usize {
    if value == 0 {
        0
    } else {
        usize::BITS as usize - 1 - value.leading_zeros() as usize
    }
}
pub fn length_bucket(length: usize) -> usize {
    match length {
        1 => 0,
        2 => 1,
        3..=4 => 2,
        _ => 3,
    }
}
