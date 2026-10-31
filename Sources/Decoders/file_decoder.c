// Picks the decoder for a file and forwards calls to it. Each decoder's struct starts with an int `kind`.
#include <stdio.h>
#include <string.h>
#include <strings.h>

#include "file_decoder.h"

int fd_ffmpeg_read(fd_decoder* d, int64_t index, uint16_t* rgba);
void fd_ffmpeg_close(fd_decoder* d);
int fd_braw_read(fd_decoder* d, int64_t index, uint16_t* rgba);
void fd_braw_close(fd_decoder* d);
int fd_libraw_read(fd_decoder* d, int64_t index, uint16_t* rgba);
void fd_libraw_close(fd_decoder* d);

enum { KIND_FFMPEG = 0, KIND_BRAW = 1, KIND_LIBRAW = 2 };

// Canon Cinema RAW Light movies and still-photo RAW formats go to LibRaw.
static const char* LIBRAW_EXTENSIONS[] = {"crm", "cr3", "cr2", "nef", "arw", "dng", "raf", "rw2", "orf", "pef", "srw", NULL};

static int has_extension(const char* path, const char* ext) {
    const char* dot = strrchr(path, '.');
    return dot && strcasecmp(dot + 1, ext) == 0;
}

static fd_decoder* open_any(const char* path, fd_info* info, char* err, int err_len) {
    if (has_extension(path, "braw")) return fd_braw_open(path, info, err, err_len);
    for (const char** e = LIBRAW_EXTENSIONS; *e; e++)
        if (has_extension(path, *e)) return fd_libraw_open(path, info, err, err_len);
    return fd_ffmpeg_open(path, info, err, err_len);
}

// Frame size limits: a file claiming an absurd size would otherwise make the app try to allocate gigabytes.
enum { MAX_DIMENSION = 16384 };
// ...and in total pixels (each copy of a 100 MP frame is 800 MB; the buffer, its copy and the texture coexist).
enum { MAX_PIXELS = 100000000 };

fd_decoder* fd_open(const char* path, fd_info* info, char* err, int err_len) {
    memset(info, 0, sizeof *info);
    fd_decoder* d = open_any(path, info, err, err_len);
    if (d && (info->width <= 0 || info->height <= 0 || info->width > MAX_DIMENSION || info->height > MAX_DIMENSION ||
                (int64_t)info->width * info->height > MAX_PIXELS)) {
        if (err && err_len > 0) snprintf(err, err_len, "unsupported frame size %dx%d", info->width, info->height);
        fd_close(d);
        return NULL;
    }
    return d;
}

int fd_read(fd_decoder* d, int64_t index, uint16_t* rgba) {
    switch (*(int*)d) {
    case KIND_BRAW: return fd_braw_read(d, index, rgba);
    case KIND_LIBRAW: return fd_libraw_read(d, index, rgba);
    default: return fd_ffmpeg_read(d, index, rgba);
    }
}

void fd_close(fd_decoder* d) {
    if (!d) return;
    switch (*(int*)d) {
    case KIND_BRAW: fd_braw_close(d); break;
    case KIND_LIBRAW: fd_libraw_close(d); break;
    default: fd_ffmpeg_close(d);
    }
}
