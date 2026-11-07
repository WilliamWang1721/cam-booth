#ifndef CAMBOOTH_CORE_H
#define CAMBOOTH_CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum { CB_KIND_PHOTO = 0, CB_KIND_VIDEO = 1 };
enum { CB_FMT_MOV = 0, CB_FMT_MP4 = 1, CB_FMT_HEVC = 2, CB_FMT_M4V = 3 };

/* All helpers write a NUL-terminated UTF-8 string into `buf` and return its
 * byte length (excluding the NUL), or -1 if `buf` is NULL / too small / the
 * input is invalid. */

/* "Cam Booth 2026-11-03 at 13.46.20.mov" — `format` picks the video
 * extension (CB_FMT_*); photos are always .jpg. */
int32_t cb_output_filename(int32_t kind, int32_t format, int64_t unix_secs,
                           int32_t tz_offset_secs, char *buf, size_t cap);

/* AVFileType identifier for a video format, e.g. "public.mpeg-4-movie". */
int32_t cb_video_file_type(int32_t format, char *buf, size_t cap);

/* avconvert preset name for a video format, e.g. "PresetHighestQuality". */
int32_t cb_video_preset(int32_t format, char *buf, size_t cap);

/* "00:07", "12:34", "1:02:03" */
int32_t cb_format_duration(uint64_t ms, char *buf, size_t cap);

#ifdef __cplusplus
}
#endif

#endif
