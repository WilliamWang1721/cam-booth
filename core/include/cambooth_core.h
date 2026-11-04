#ifndef CAMBOOTH_CORE_H
#define CAMBOOTH_CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum { CB_KIND_PHOTO = 0, CB_KIND_VIDEO = 1 };

/* Both functions write a NUL-terminated UTF-8 string into `buf` and return its
 * byte length (excluding the NUL), or -1 if `buf` is NULL / too small / the
 * input is invalid. */

/* "Cam Booth 2026-11-03 at 13.46.20.mov" */
int32_t cb_output_filename(int32_t kind, int64_t unix_secs, int32_t tz_offset_secs,
                           char *buf, size_t cap);

/* "00:07", "12:34", "1:02:03" */
int32_t cb_format_duration(uint64_t ms, char *buf, size_t cap);

#ifdef __cplusplus
}
#endif

#endif
