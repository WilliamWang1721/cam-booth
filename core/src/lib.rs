//! Cam Booth core.
//!
//! Deliberately small: capture and hardware encoding stay in AVFoundation /
//! VideoToolbox (the system already does zero-copy, hardware-accelerated work
//! there). The core owns the pure logic that does not need the OS: file naming
//! and time formatting. No dependencies, no allocation across the FFI boundary:
//! callers pass in a buffer and get a byte length back (or -1 if it is too small).

use std::os::raw::c_char;

pub const KIND_PHOTO: i32 = 0;
pub const KIND_VIDEO: i32 = 1;

/// Days since 1970-01-01 -> (year, month, day), proleptic Gregorian.
/// Howard Hinnant's `civil_from_days`.
fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = (if mp < 10 { mp + 3 } else { mp - 9 }) as u32;
    let y = yoe + era * 400 + i64::from(m <= 2);
    (y, m, d)
}

/// "Cam Booth 2026-11-03 at 13.46.20.mov" (same shape macOS uses for its own captures).
pub fn output_filename(kind: i32, unix_secs: i64, tz_offset_secs: i32) -> Option<String> {
    let ext = match kind {
        KIND_PHOTO => "jpg",
        KIND_VIDEO => "mov",
        _ => return None,
    };
    let local = unix_secs.checked_add(i64::from(tz_offset_secs))?;
    let (y, mo, d) = civil_from_days(local.div_euclid(86_400));
    let sod = local.rem_euclid(86_400);
    let (h, mi, s) = (sod / 3_600, (sod % 3_600) / 60, sod % 60);
    Some(format!(
        "Cam Booth {y:04}-{mo:02}-{d:02} at {h:02}.{mi:02}.{s:02}.{ext}"
    ))
}

/// "00:07", "12:34", "1:02:03".
pub fn format_duration(ms: u64) -> String {
    let total = ms / 1_000;
    let (h, m, s) = (total / 3_600, (total % 3_600) / 60, total % 60);
    if h > 0 {
        format!("{h}:{m:02}:{s:02}")
    } else {
        format!("{m:02}:{s:02}")
    }
}

/// Copy `s` plus a NUL into `buf`. Returns the byte length (without NUL) or -1.
///
/// # Safety
/// `buf` must be null or valid for writes of `cap` bytes.
unsafe fn write_cstr(s: &str, buf: *mut c_char, cap: usize) -> i32 {
    let bytes = s.as_bytes();
    if buf.is_null() || cap < bytes.len() + 1 {
        return -1;
    }
    std::ptr::copy_nonoverlapping(bytes.as_ptr(), buf.cast::<u8>(), bytes.len());
    *buf.add(bytes.len()) = 0;
    bytes.len() as i32
}

/// # Safety
/// `buf` must be null or valid for writes of `cap` bytes.
#[no_mangle]
pub unsafe extern "C" fn cb_output_filename(
    kind: i32,
    unix_secs: i64,
    tz_offset_secs: i32,
    buf: *mut c_char,
    cap: usize,
) -> i32 {
    match output_filename(kind, unix_secs, tz_offset_secs) {
        Some(name) => write_cstr(&name, buf, cap),
        None => -1,
    }
}

/// # Safety
/// `buf` must be null or valid for writes of `cap` bytes.
#[no_mangle]
pub unsafe extern "C" fn cb_format_duration(ms: u64, buf: *mut c_char, cap: usize) -> i32 {
    write_cstr(&format_duration(ms), buf, cap)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CStr;

    #[test]
    fn epoch() {
        assert_eq!(
            output_filename(KIND_VIDEO, 0, 0).unwrap(),
            "Cam Booth 1970-01-01 at 00.00.00.mov"
        );
    }

    #[test]
    fn known_timestamps() {
        // 2001-09-09 01:46:40 UTC
        assert_eq!(
            output_filename(KIND_PHOTO, 1_000_000_000, 0).unwrap(),
            "Cam Booth 2001-09-09 at 01.46.40.jpg"
        );
        // same instant at UTC+8
        assert_eq!(
            output_filename(KIND_PHOTO, 1_000_000_000, 8 * 3_600).unwrap(),
            "Cam Booth 2001-09-09 at 09.46.40.jpg"
        );
        // leap day: 2000-02-29 00:00:00 UTC
        assert_eq!(
            output_filename(KIND_VIDEO, 951_782_400, 0).unwrap(),
            "Cam Booth 2000-02-29 at 00.00.00.mov"
        );
    }

    #[test]
    fn before_epoch_and_day_rollover() {
        assert_eq!(
            output_filename(KIND_VIDEO, -1, 0).unwrap(),
            "Cam Booth 1969-12-31 at 23.59.59.mov"
        );
        // 23:00 UTC at UTC+2 is 01:00 the next day
        assert_eq!(
            output_filename(KIND_VIDEO, 82_800, 2 * 3_600).unwrap(),
            "Cam Booth 1970-01-02 at 01.00.00.mov"
        );
    }

    #[test]
    fn bad_kind() {
        assert!(output_filename(7, 0, 0).is_none());
    }

    #[test]
    fn durations() {
        assert_eq!(format_duration(0), "00:00");
        assert_eq!(format_duration(999), "00:00");
        assert_eq!(format_duration(7_000), "00:07");
        assert_eq!(format_duration(754_000), "12:34");
        assert_eq!(format_duration(3_723_000), "1:02:03");
    }

    #[test]
    fn ffi_roundtrip_and_small_buffer() {
        let mut buf = [0 as c_char; 64];
        let n = unsafe { cb_format_duration(7_000, buf.as_mut_ptr(), buf.len()) };
        assert_eq!(n, 5);
        let s = unsafe { CStr::from_ptr(buf.as_ptr()) }.to_str().unwrap();
        assert_eq!(s, "00:07");

        // exactly len+1 fits, len does not
        let mut tight = [0 as c_char; 5];
        assert_eq!(unsafe { cb_format_duration(7_000, tight.as_mut_ptr(), 5) }, -1);
        let mut ok = [0 as c_char; 6];
        assert_eq!(unsafe { cb_format_duration(7_000, ok.as_mut_ptr(), 6) }, 5);
        assert_eq!(unsafe { cb_format_duration(7_000, std::ptr::null_mut(), 64) }, -1);
        assert_eq!(
            unsafe { cb_output_filename(9, 0, 0, buf.as_mut_ptr(), buf.len()) },
            -1
        );
    }
}
