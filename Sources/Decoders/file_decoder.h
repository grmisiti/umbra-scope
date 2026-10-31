// Frame-accurate decoders for files AVFoundation doesn't read: FFmpeg (MXF/XAVC, DNxHR, CineForm, ProRes RAW…),
// the Blackmagic RAW SDK (BRAW) and LibRaw (Canon Cinema RAW Light .crm, photo RAW). Every decoder hands out RGBA 16-bit unsigned (0..65535), rows top-down.
#ifndef FILE_DECODER_H
#define FILE_DECODER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct fd_info {
    int width, height;
    double fps;
    int64_t frame_count;     // 0 when unknown
    int bit_depth;           // of the stored picture, when known
    char codec[64];          // e.g. "prores (ffmpeg)", "Blackmagic RAW"
} fd_info;

typedef struct fd_decoder fd_decoder;

/// Opens a file with the decoder suited to it (BRAW SDK for .braw, FFmpeg otherwise). On failure returns NULL
/// and writes a message into err.
fd_decoder* fd_open(const char* path, fd_info* info, char* err, int err_len);

/// Decodes frame `index` into `rgba` (width * height * 4 values). Returns 0 on success, 1 past the end, <0 on error.
int fd_read(fd_decoder* d, int64_t index, uint16_t* rgba);

void fd_close(fd_decoder* d);

// Implementations (selected by fd_open).
fd_decoder* fd_ffmpeg_open(const char* path, fd_info* info, char* err, int err_len);
fd_decoder* fd_braw_open(const char* path, fd_info* info, char* err, int err_len);
fd_decoder* fd_libraw_open(const char* path, fd_info* info, char* err, int err_len);

#ifdef __cplusplus
}
#endif

#endif
