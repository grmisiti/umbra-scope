// Umbra Link wire protocol, version 1: the Umbra Link OFX plugin (ZeroMQ XPUB) sends frames to Umbra Scope (SUB).
//
// Each message has two parts: [ul_frame_header][pixels]. Pixels are tightly packed, rows top-down, in the format
// the header names. The plugin re-sends its last frame whenever a receiver subscribes, so a paused frame can be read.
#ifndef UMBRALINK_PROTOCOL_H
#define UMBRALINK_PROTOCOL_H

#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <unistd.h>

#define UL_MAGIC 0x4B4E4C55u   /* "ULNK" read as a little-endian uint32 */
#define UL_VERSION 1

enum ul_format {
    UL_FORMAT_RGBA16 = 1,      // 4 x uint16, 0..65535
    UL_FORMAT_RGBA32F = 2,     // 4 x float, 0..1
};

enum ul_flags {
    UL_FLAG_LEGAL_RANGE = 1u << 0,   // code values are video range (64-940 of 1023)
    UL_FLAG_DOWNSCALED = 1u << 1,    // smaller than the host's frame
};

typedef struct ul_frame_header {
    uint32_t magic;          // UL_MAGIC
    uint16_t version;        // UL_VERSION
    uint16_t header_bytes;   // sizeof(ul_frame_header), so later versions can grow it
    uint32_t width;          // pixels in this message
    uint32_t height;
    uint32_t format;         // ul_format
    uint32_t flags;          // ul_flags
    uint64_t frame;          // host frame number
    double seconds;          // host time in seconds
    double fps;              // host frame rate, 0 if unknown
    uint8_t timecode[4];     // hours, minutes, seconds, frames
    uint32_t reserved[3];
} ul_frame_header;

#ifdef __cplusplus
static_assert(sizeof(ul_frame_header) == 64, "header must be 64 bytes");
#else
_Static_assert(sizeof(ul_frame_header) == 64, "header must be 64 bytes");
#endif

/// Bytes per pixel of a format, 0 if unknown.
static inline size_t ul_bytes_per_pixel(uint32_t format) {
    return format == UL_FORMAT_RGBA16 ? 8 : format == UL_FORMAT_RGBA32F ? 16 : 0;
}

/// The socket lives in the user's private temp folder (/var/folders/…/T/, mode 0700) instead of /tmp, so other
/// accounts on the Mac can neither watch the frames nor pose as the plugin. Plugin and app run as the same user,
/// so both resolve the same folder.
#define UL_SOCKET_NAME "umbrascope.link"
/// Frames are rejected above this size on either side (Metal's texture limit), and messages above this many bytes.
#define UL_MAX_DIMENSION 16384
/// Total pixels per frame (100 MP: 12K and beyond fit; a 16384 x 16384 header, ~2 GiB per copy, does not).
#define UL_MAX_PIXELS 100000000
#define UL_MAX_MESSAGE_BYTES (1LL << 30)

/// Writes "ipc://<per-user temp folder>/umbrascope.link" into buf. Returns 0, or -1 if the folder is unknown or the
/// path would not fit in a Unix socket address (104 bytes).
static inline int ul_endpoint(char* buf, size_t len) {
    char dir[512];
    size_t n = confstr(_CS_DARWIN_USER_TEMP_DIR, dir, sizeof dir);
    if (n == 0 || n > sizeof dir) return -1;
    int w = snprintf(buf, len, "ipc://%s%s", dir, UL_SOCKET_NAME);
    if (w <= 0 || (size_t)w >= len || w - 6 >= 104) return -1;
    return 0;
}

#endif
