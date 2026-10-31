// FFmpeg decoder: any container/codec libavformat/libavcodec reads (MXF with Sony XAVC Intra/Long GOP, XDCAM,
// DNxHD/HR, CineForm, HEVC/H.264 10-bit, Apple ProRes RAW, Cintel RAW…). Frames are converted with swscale to
// RGB 16-bit using the stream's own matrix and range, then expanded to RGBA.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/imgutils.h>
#include <libavutil/pixdesc.h>
#include <libswscale/swscale.h>

#include "file_decoder.h"

void fd_ffmpeg_close(struct fd_decoder* d);

struct fd_decoder {
    int kind;                 // 0 = ffmpeg (shared layout with the BRAW decoder's first field)
    AVFormatContext* fmt;
    AVCodecContext* dec;
    int stream;
    AVFrame* frame;
    AVPacket* pkt;
    struct SwsContext* sws;
    int sws_w, sws_h, sws_fmt, sws_space, sws_range;
    uint16_t* rgb48;          // swscale output before adding alpha
    int width, height;
    double fps;
    AVRational time_base;
    int64_t start_pts;
    int64_t next_index;       // index of the frame the decoder will produce next, -1 after a seek
};

static void set_err(char* err, int len, const char* msg, int code) {
    if (!err || len <= 0) return;
    if (code < 0) {
        char buf[128];
        av_strerror(code, buf, sizeof buf);
        snprintf(err, len, "%s: %s", msg, buf);
    } else {
        snprintf(err, len, "%s", msg);
    }
}

static int64_t index_of(struct fd_decoder* d, int64_t pts) {
    if (pts == AV_NOPTS_VALUE) return -1;
    double t = (double)(pts - d->start_pts) * av_q2d(d->time_base);
    return (int64_t)(t * d->fps + 0.5);
}

fd_decoder* fd_ffmpeg_open(const char* path, fd_info* info, char* err, int err_len) {
    struct fd_decoder* d = calloc(1, sizeof *d);
    if (!d) { set_err(err, err_len, "out of memory", 0); return NULL; }
    int r;
    // Local files only: a crafted file (playlist, concat list, reference) must never make FFmpeg open a network URL
    // or another protocol. The whitelist is inherited by anything the demuxer opens on its own.
    AVDictionary* opts = NULL;
    av_dict_set(&opts, "protocol_whitelist", "file", 0);
    r = avformat_open_input(&d->fmt, path, NULL, &opts);
    av_dict_free(&opts);
    if (r < 0) { set_err(err, err_len, "open", r); free(d); return NULL; }
    if ((r = avformat_find_stream_info(d->fmt, NULL)) < 0) { set_err(err, err_len, "stream info", r); goto fail; }
    d->stream = av_find_best_stream(d->fmt, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (d->stream < 0) { set_err(err, err_len, "no video stream", 0); goto fail; }
    AVStream* st = d->fmt->streams[d->stream];
    const AVCodec* codec = avcodec_find_decoder(st->codecpar->codec_id);
    if (!codec) { set_err(err, err_len, "FFmpeg has no decoder for this codec", 0); goto fail; }
    d->dec = avcodec_alloc_context3(codec);
    avcodec_parameters_to_context(d->dec, st->codecpar);
    d->dec->thread_count = 0;   // all cores
    if ((r = avcodec_open2(d->dec, codec, NULL)) < 0) { set_err(err, err_len, "decoder", r); goto fail; }

    d->frame = av_frame_alloc();
    d->pkt = av_packet_alloc();
    d->width = d->dec->width;
    d->height = d->dec->height;
    AVRational fr = av_guess_frame_rate(d->fmt, st, NULL);
    d->fps = fr.num > 0 && fr.den > 0 ? av_q2d(fr) : 24.0;
    d->time_base = st->time_base;
    d->start_pts = st->start_time != AV_NOPTS_VALUE ? st->start_time : 0;
    d->next_index = 0;

    info->width = d->width;
    info->height = d->height;
    info->fps = d->fps;
    info->frame_count = st->nb_frames > 0 ? st->nb_frames
                      : (d->fmt->duration > 0 ? (int64_t)(d->fmt->duration / (double)AV_TIME_BASE * d->fps) : 0);
    const AVPixFmtDescriptor* desc = av_pix_fmt_desc_get(d->dec->pix_fmt);
    info->bit_depth = desc ? desc->comp[0].depth : 0;
    snprintf(info->codec, sizeof info->codec, "%s (FFmpeg)", codec->name);
    return d;

fail:
    fd_ffmpeg_close(d);
    return NULL;
}

// Decodes the next frame into d->frame. Returns 0, 1 at end of file, <0 on error.
static int decode_next(struct fd_decoder* d) {
    for (;;) {
        int r = avcodec_receive_frame(d->dec, d->frame);
        if (r == 0) return 0;
        if (r == AVERROR_EOF) return 1;
        if (r != AVERROR(EAGAIN)) return r;
        r = av_read_frame(d->fmt, d->pkt);
        if (r == AVERROR_EOF) { avcodec_send_packet(d->dec, NULL); continue; }
        if (r < 0) return r;
        if (d->pkt->stream_index == d->stream) avcodec_send_packet(d->dec, d->pkt);
        av_packet_unref(d->pkt);
    }
}

static int convert(struct fd_decoder* d, uint16_t* rgba) {
    AVFrame* f = d->frame;
    // Matrix and range from the stream; unknown matrices follow the usual HD/SD rule.
    int space = f->colorspace;
    if (space == AVCOL_SPC_UNSPECIFIED) space = f->height >= 720 ? AVCOL_SPC_BT709 : AVCOL_SPC_SMPTE170M;
    int full = f->color_range == AVCOL_RANGE_JPEG;
    if (!d->sws || d->sws_w != f->width || d->sws_h != f->height || d->sws_fmt != f->format ||
        d->sws_space != space || d->sws_range != full) {
        sws_freeContext(d->sws);
        d->sws = sws_getContext(f->width, f->height, f->format, d->width, d->height, AV_PIX_FMT_RGB48LE,
                                SWS_BICUBIC | SWS_ACCURATE_RND | SWS_FULL_CHR_H_INT, NULL, NULL, NULL);
        if (!d->sws) return -1;
        const int* coefs = sws_getCoefficients(space == AVCOL_SPC_BT2020_NCL || space == AVCOL_SPC_BT2020_CL ? SWS_CS_BT2020
                                               : space == AVCOL_SPC_BT709 ? SWS_CS_ITU709 : SWS_CS_ITU601);
        // Output full range RGB: video-range sources are expanded so 0..1 means black..white.
        sws_setColorspaceDetails(d->sws, coefs, full, coefs, 1, 0, 1 << 16, 1 << 16);
        d->sws_w = f->width; d->sws_h = f->height; d->sws_fmt = f->format; d->sws_space = space; d->sws_range = full;
        free(d->rgb48);
        d->rgb48 = malloc((size_t)d->width * d->height * 6);
        if (!d->rgb48) { sws_freeContext(d->sws); d->sws = NULL; return -1; }
    }
    uint8_t* dst[4] = {(uint8_t*)d->rgb48, NULL, NULL, NULL};
    int dst_stride[4] = {d->width * 6, 0, 0, 0};
    if (sws_scale(d->sws, (const uint8_t* const*)f->data, f->linesize, 0, f->height, dst, dst_stride) <= 0) return -1;
    size_t n = (size_t)d->width * d->height;
    for (size_t i = 0; i < n; i++) {
        rgba[i * 4 + 0] = d->rgb48[i * 3 + 0];
        rgba[i * 4 + 1] = d->rgb48[i * 3 + 1];
        rgba[i * 4 + 2] = d->rgb48[i * 3 + 2];
        rgba[i * 4 + 3] = 65535;
    }
    return 0;
}

int fd_ffmpeg_read(struct fd_decoder* d, int64_t index, uint16_t* rgba) {
    if (index != d->next_index) {
        // Seek to the keyframe before the target, then decode forward to it.
        AVStream* st = d->fmt->streams[d->stream];
        int64_t ts = d->start_pts + (int64_t)((double)index / d->fps / av_q2d(st->time_base));
        if (av_seek_frame(d->fmt, d->stream, ts, AVSEEK_FLAG_BACKWARD) < 0) return -1;
        avcodec_flush_buffers(d->dec);
        d->next_index = -1;
    }
    for (;;) {
        int r = decode_next(d);
        if (r != 0) return r;
        int64_t i = index_of(d, d->frame->best_effort_timestamp);
        if (i < 0) i = d->next_index < 0 ? index : d->next_index;   // no timestamps: assume sequential
        d->next_index = i + 1;
        if (i < index) { av_frame_unref(d->frame); continue; }
        r = convert(d, rgba);
        av_frame_unref(d->frame);
        return r;
    }
}

void fd_ffmpeg_close(struct fd_decoder* d) {
    if (!d) return;
    sws_freeContext(d->sws);
    free(d->rgb48);
    av_frame_free(&d->frame);
    av_packet_free(&d->pkt);
    avcodec_free_context(&d->dec);
    avformat_close_input(&d->fmt);
    free(d);
}
