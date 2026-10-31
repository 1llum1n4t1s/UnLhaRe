//! 複数入力をまとめて計測するための、メモリ内専用 manifest。
//! 製品の永続形式ではなく、ファイルシステムへ展開する機能も持たない。

use crate::khc::{Error, MAX_INPUT};

const MAGIC_V0: &[u8; 8] = b"KHSGRP0\0";
const MAGIC_V1: &[u8; 8] = b"KHSGRP1\0";
const HEADER: usize = 16;
const MAX_ENTRIES: u32 = 1024;
const MAX_NAME: usize = 255;

struct Metadata<'a> {
    name: &'a str,
    data_len: usize,
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct Entry<'a> {
    pub(crate) name: &'a str,
    pub(crate) data: &'a [u8],
}

fn take<'a>(
    input: &'a [u8],
    cursor: &mut usize,
    length: usize,
    error: &'static str,
) -> Result<&'a [u8], Error> {
    let end = cursor.checked_add(length).ok_or(Error::Limit)?;
    let bytes = input.get(*cursor..end).ok_or(Error::Format(error))?;
    *cursor = end;
    Ok(bytes)
}

fn read_u16(input: &[u8], cursor: &mut usize, error: &'static str) -> Result<u16, Error> {
    let bytes =
        <[u8; 2]>::try_from(take(input, cursor, 2, error)?).map_err(|_| Error::Format(error))?;
    Ok(u16::from_le_bytes(bytes))
}

fn read_u32(input: &[u8], cursor: &mut usize, error: &'static str) -> Result<u32, Error> {
    let bytes =
        <[u8; 4]>::try_from(take(input, cursor, 4, error)?).map_err(|_| Error::Format(error))?;
    Ok(u32::from_le_bytes(bytes))
}

fn read_u64(input: &[u8], cursor: &mut usize, error: &'static str) -> Result<u64, Error> {
    let bytes =
        <[u8; 8]>::try_from(take(input, cursor, 8, error)?).map_err(|_| Error::Format(error))?;
    Ok(u64::from_le_bytes(bytes))
}

fn valid_name(name: &str) -> bool {
    name != "."
        && name != ".."
        && !name
            .chars()
            .any(|ch| ch == '/' || ch == '\\' || ch == ':' || ch == '\0' || ch.is_control())
}

/// 研究用 solid group を借用 view として検証・解析する。
pub(crate) fn parse(input: &[u8]) -> Result<Vec<Entry<'_>>, Error> {
    if input.len() > MAX_INPUT {
        return Err(Error::Limit);
    }
    if input.len() < HEADER {
        return Err(Error::Format("group header"));
    }

    let mut metadata_cursor = 0;
    let magic = take(input, &mut metadata_cursor, MAGIC_V0.len(), "group header")?;
    let has_physical_order = if magic == MAGIC_V0 {
        false
    } else if magic == MAGIC_V1 {
        true
    } else {
        return Err(Error::Format("group magic"));
    };
    let count = read_u32(input, &mut metadata_cursor, "group header")?;
    let reserved = read_u32(input, &mut metadata_cursor, "group header")?;
    if reserved != 0 {
        return Err(Error::Format("group reserved"));
    }
    if count > MAX_ENTRIES {
        return Err(Error::Limit);
    }
    let count = usize::try_from(count).map_err(|_| Error::Limit)?;
    // 本文へ触れる前に、metadata全件・名前順・宣言総量を検証する。
    let mut total_data = 0usize;
    let mut previous_name: Option<&[u8]> = None;
    let mut metadata = Vec::new();
    metadata
        .try_reserve_exact(count)
        .map_err(|_| Error::Limit)?;
    for _ in 0..count {
        let name_len = usize::from(read_u16(input, &mut metadata_cursor, "group metadata")?);
        let data_len = usize::try_from(read_u64(input, &mut metadata_cursor, "group metadata")?)
            .map_err(|_| Error::Limit)?;
        if !(1..=MAX_NAME).contains(&name_len) {
            return Err(Error::Format("entry name length"));
        }
        let name_bytes = take(input, &mut metadata_cursor, name_len, "group metadata")?;
        let name =
            std::str::from_utf8(name_bytes).map_err(|_| Error::Format("entry name utf-8"))?;
        if !valid_name(name) {
            return Err(Error::Format("entry name"));
        }
        if previous_name.is_some_and(|previous| previous >= name_bytes) {
            return Err(Error::Format("entry order"));
        }
        previous_name = Some(name_bytes);
        total_data = total_data.checked_add(data_len).ok_or(Error::Limit)?;
        metadata.push(Metadata { name, data_len });
    }

    // KHSGRP1のtableは物理順ごとに論理Entry indexを持つ。範囲と重複を
    // 全て検証してから本文sliceを構築する。
    let mut logical_by_physical = Vec::new();
    logical_by_physical
        .try_reserve_exact(count)
        .map_err(|_| Error::Limit)?;
    let mut physical_position_by_logical = Vec::new();
    physical_position_by_logical
        .try_reserve_exact(count)
        .map_err(|_| Error::Limit)?;
    physical_position_by_logical.resize(count, usize::MAX);
    if has_physical_order {
        for physical_position in 0..count {
            let logical_index = usize::from(read_u16(
                input,
                &mut metadata_cursor,
                "group physical order",
            )?);
            if logical_index >= count || physical_position_by_logical[logical_index] != usize::MAX {
                return Err(Error::Format("group physical order"));
            }
            physical_position_by_logical[logical_index] = physical_position;
            logical_by_physical.push(logical_index);
        }
    } else {
        for (logical_index, physical_position) in
            physical_position_by_logical.iter_mut().enumerate()
        {
            *physical_position = logical_index;
            logical_by_physical.push(logical_index);
        }
    }

    let data_start = metadata_cursor;
    let expected_len = data_start.checked_add(total_data).ok_or(Error::Limit)?;
    if expected_len > MAX_INPUT {
        return Err(Error::Limit);
    }
    if input.len() < expected_len {
        return Err(Error::Format("group data"));
    }
    if input.len() > expected_len {
        return Err(Error::Format("group trailing data"));
    }

    let mut data_offsets = Vec::new();
    data_offsets
        .try_reserve_exact(count)
        .map_err(|_| Error::Limit)?;
    data_offsets.resize(count, 0usize);
    let mut data_cursor = data_start;
    for logical_index in logical_by_physical {
        data_offsets[logical_index] = data_cursor;
        data_cursor = data_cursor
            .checked_add(metadata[logical_index].data_len)
            .ok_or(Error::Limit)?;
    }
    if data_cursor != expected_len {
        return Err(Error::Format("group data"));
    }

    let mut entries = Vec::new();
    entries.try_reserve_exact(count).map_err(|_| Error::Limit)?;
    for (logical_index, item) in metadata.into_iter().enumerate() {
        let data_start = data_offsets[logical_index];
        let data_end = data_start.checked_add(item.data_len).ok_or(Error::Limit)?;
        let data = input
            .get(data_start..data_end)
            .ok_or(Error::Format("group data"))?;
        entries.push(Entry {
            name: item.name,
            data,
        });
    }
    Ok(entries)
}

#[cfg(test)]
mod tests {
    use super::{Entry, MAX_ENTRIES, parse};
    use crate::khc::{Algorithm, Error, MAX_INPUT, Options, decode, encode};

    fn fixture(entries: &[(&[u8], &[u8])]) -> Vec<u8> {
        let mut bytes = Vec::new();
        // parser側の定数や補助関数を使わず、wire仕様から独立に構築する。
        bytes.extend_from_slice(b"KHSGRP0\0");
        bytes.extend_from_slice(&u32::try_from(entries.len()).unwrap().to_le_bytes());
        bytes.extend_from_slice(&0u32.to_le_bytes());
        for (name, data) in entries {
            bytes.extend_from_slice(&u16::try_from(name.len()).unwrap().to_le_bytes());
            bytes.extend_from_slice(&u64::try_from(data.len()).unwrap().to_le_bytes());
            bytes.extend_from_slice(name);
        }
        for (_, data) in entries {
            bytes.extend_from_slice(data);
        }
        bytes
    }

    fn assert_format(input: &[u8]) {
        assert!(matches!(parse(input), Err(Error::Format(_))));
    }

    #[test]
    fn parses_golden_group() {
        let bytes = fixture(&[(b"alpha.txt", b"alpha"), (b"beta.bin", &[0, 1, 2, 255])]);
        assert_eq!(
            parse(&bytes),
            Ok(vec![
                Entry {
                    name: "alpha.txt",
                    data: b"alpha"
                },
                Entry {
                    name: "beta.bin",
                    data: &[0, 1, 2, 255]
                }
            ])
        );
    }

    #[test]
    fn accepts_utf8_names_and_empty_groups_and_files() {
        let empty = fixture(&[]);
        assert_eq!(empty.len(), 16);
        assert_eq!(parse(&empty), Ok(Vec::new()));

        let bytes = fixture(&[("あ.txt".as_bytes(), b""), ("猫.bin".as_bytes(), b"cat")]);
        let entries = parse(&bytes).unwrap();
        assert_eq!(
            entries[0],
            Entry {
                name: "あ.txt",
                data: b""
            }
        );
        assert_eq!(
            entries[1],
            Entry {
                name: "猫.bin",
                data: b"cat"
            }
        );
    }

    #[test]
    fn rejects_duplicate_and_out_of_order_names() {
        assert_format(&fixture(&[(b"same", b"a"), (b"same", b"b")]));
        assert_format(&fixture(&[(b"z", b"a"), (b"a", b"b")]));
    }

    #[test]
    fn rejects_declared_length_overflow() {
        let mut bytes = fixture(&[(b"a", b"")]);
        bytes[18..26].copy_from_slice(&u64::MAX.to_le_bytes());
        assert_eq!(parse(&bytes), Err(Error::Limit));
    }

    #[test]
    fn rejects_every_truncation_and_trailing_data() {
        let bytes = fixture(&[(b"a", b"one"), (b"b", b"two")]);
        for end in 0..bytes.len() {
            assert!(
                parse(&bytes[..end]).is_err(),
                "accepted truncation at {end}"
            );
        }
        let mut trailing = bytes;
        trailing.push(0);
        assert_format(&trailing);
    }

    #[test]
    fn enforces_resource_limits() {
        let oversized = vec![0; MAX_INPUT + 1];
        assert_eq!(parse(&oversized), Err(Error::Limit));

        let mut too_many = fixture(&[]);
        too_many[8..12].copy_from_slice(&(MAX_ENTRIES + 1).to_le_bytes());
        assert_eq!(parse(&too_many), Err(Error::Limit));

        let mut declared_too_large = fixture(&[(b"a", b"")]);
        declared_too_large[18..26]
            .copy_from_slice(&u64::try_from(MAX_INPUT).unwrap().to_le_bytes());
        assert_eq!(parse(&declared_too_large), Err(Error::Limit));
    }

    #[test]
    fn rejects_invalid_names() {
        for name in [
            b"".as_slice(),
            b".".as_slice(),
            b"..".as_slice(),
            b"a/b".as_slice(),
            b"a\\b".as_slice(),
            b"a:b".as_slice(),
            b"a\0b".as_slice(),
            b"a\nb".as_slice(),
            &[0xc3, 0x28],
        ] {
            assert_format(&fixture(&[(name, b"")]));
        }

        let long_name = vec![b'a'; 256];
        assert_format(&fixture(&[(&long_name, b"")]));
    }

    #[test]
    fn rejects_header_and_metadata_corruption() {
        let mut bad_magic = fixture(&[]);
        bad_magic[0] ^= 1;
        assert_format(&bad_magic);

        let mut reserved = fixture(&[]);
        reserved[12] = 1;
        assert_format(&reserved);

        let mut missing_name = fixture(&[(b"a", b"")]);
        missing_name.truncate(16 + 10);
        assert_format(&missing_name);
    }

    #[test]
    fn validates_all_metadata_before_slicing_data() {
        let mut bytes = fixture(&[(b"a", b"payload"), (b"b", b"more")]);
        // 2つ目の名前を順序違反にし、payloadも全て落とす。
        let second_name = 16 + 2 + 8 + 1 + 2 + 8;
        bytes[second_name] = b'a';
        bytes.truncate(second_name + 1);
        assert_eq!(parse(&bytes), Err(Error::Format("entry order")));
    }

    #[test]
    fn khc_round_trip_preserves_representative_entries() {
        let repeated: Vec<u8> = (0..4096).map(|at| (at * 73 + 19) as u8).collect();
        let group = fixture(&[(b"a", &repeated), (b"b", &repeated), (b"empty", b"")]);
        for algorithm in [Algorithm::Lz, Algorithm::Beam] {
            let options = Options {
                algorithm,
                beam_width: 2,
                beam_matches: crate::khc::BeamMatches::Bt4,
                ..Options::default()
            };
            // entry別の往復ではなく、名前・境界表を含むgroup全体を1回で符号化する。
            let frame = encode(&group, options, &mut || false).unwrap();
            assert!(frame.len() < group.len());
            let restored = decode(&frame, options, &mut || false).unwrap();
            assert_eq!(restored, group);
            assert_eq!(parse(&restored), parse(&group));
        }
    }
}
