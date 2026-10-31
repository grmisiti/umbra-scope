// LibRaw decoder: Canon Cinema RAW Light movies (.crm, the same CRX codec as CR3 stills) frame by frame, and
// still-photo RAW files (CR3/CR2, NEF, ARW, DNG, RAF…), demosaiced with the camera's white balance and no automatic
// brightening, so the scopes read the recorded exposure.
//  - Stills: Rec.709 primaries, BT.709 curve.
//  - CRM: Canon Log 3 / Cinema Gamut, like the camera's own XF-AVC, calibrated against an EOS R5 C (ISO 800):
//    LibRaw reports black = 0 for CRM, but a lens-cap clip reads 254 of 4095, so that black is subtracted; LibRaw's
//    linear XYZ goes to Cinema Gamut, is scaled by kCrmExposure so an 18% grey card lands on the same code as the
//    XF-AVC clip of the same card, and is encoded with Canon Log 3.
#include <cmath>
#include <cstdio>
#include <cstring>
#include <memory>
#include <vector>

#include "libraw/libraw.h"

extern "C" {
#include <libavformat/avformat.h>
}

#include "file_decoder.h"

struct fd_decoder {
    int kind = 2;
    std::unique_ptr<LibRaw> raw;
    std::string path;
    int width = 0, height = 0;
    int64_t frames = 1;
    bool canonLog3 = false;   // CRM: Canon Log 3 / Cinema Gamut output
};

namespace {

// Canon Cinema RAW Light (EOS R5 C, 12-bit): black level measured with the lens cap on (LibRaw reports 0).
constexpr unsigned kCrmBlack = 254;
// LibRaw linear XYZ (white = 1) to Canon Log 3 scene linear: an 18% grey card exposed to 437.9/1023 in the camera's
// Canon Log 3 XF-AVC reads Y = 0.3197 in LibRaw's linear XYZ from the RAW clip of the same card.
constexpr double kCrmExposure = 1.2100;
// XYZ (D65) to Canon Cinema Gamut, from its primaries R 0.74/0.27, G 0.17/1.14, B 0.08/-0.10 and D65 white.
constexpr double kXyzToCinemaGamut[3][3] = {
    {1.489818, -0.260896, -0.142427},
    {-0.458167, 1.261628, 0.159624},
    {-0.070350, 0.221558, 0.776182},
};

// Canon Log 3 (Canon's published formula), scene linear -> normalised code value.
double canonLog3(double x) {
    if (x < -0.014) return -0.36726845 * std::log10(-x * 14.98325 + 1) + 0.12783901;
    if (x <= 0.014) return 1.9754798 * x + 0.12512219;
    return 0.36726845 * std::log10(x * 14.98325 + 1) + 0.12240537;
}

// Canon Log 3 lookup over scene linear 0…kLutMax (LibRaw output is never negative), 1/16384 steps.
constexpr double kLutMax = 4.0;
const std::vector<uint16_t>& canonLog3Lut() {
    static const std::vector<uint16_t> lut = [] {
        std::vector<uint16_t> t(size_t(kLutMax * 16384) + 1);
        for (size_t i = 0; i < t.size(); i++)
            t[i] = uint16_t(std::lround(std::fmin(std::fmax(canonLog3(double(i) / 16384), 0.0), 1.0) * 65535));
        return t;
    }();
    return lut;
}

// Frame rate of a RAW movie from its QuickTime container (LibRaw doesn't report it).
double containerFrameRate(const char* path) {
    AVFormatContext* fmt = nullptr;
    double fps = 0;
    AVDictionary* opts = nullptr;
    av_dict_set(&opts, "protocol_whitelist", "file", 0);   // local files only (see ffmpeg_decoder.c)
    int opened = avformat_open_input(&fmt, path, nullptr, &opts);
    av_dict_free(&opts);
    if (opened == 0) {
        if (avformat_find_stream_info(fmt, nullptr) >= 0) {
            int s = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
            if (s >= 0) {
                AVRational r = fmt->streams[s]->avg_frame_rate;
                if (r.num > 0 && r.den > 0) fps = av_q2d(r);
            }
        }
        avformat_close_input(&fmt);
    }
    return fps;
}

void configure(LibRaw& raw, unsigned shot, bool canonLog3) {
    auto& p = raw.imgdata.params;
    p.output_bps = 16;
    p.use_camera_wb = 1;       // as shot
    p.no_auto_bright = 1;      // keep the recorded exposure
    p.user_qual = 0;           // bilinear demosaic: fast, enough for scopes and noise
    if (canonLog3) {
        p.output_color = 5;    // linear XYZ; Cinema Gamut and Canon Log 3 are applied in fd_libraw_read
        p.gamm[0] = 1.0;
        p.gamm[1] = 1.0;
        p.user_black = int(kCrmBlack);
    } else {
        p.output_color = 1;    // sRGB / Rec.709 primaries; default gamma (0.45, 4.5) is the BT.709 curve
    }
    raw.imgdata.rawparams.shot_select = shot;
}

bool hasExtension(const std::string& path, const char* ext) {
    auto dot = path.rfind('.');
    return dot != std::string::npos && strcasecmp(path.c_str() + dot + 1, ext) == 0;
}

}  // namespace

extern "C" void fd_libraw_close(fd_decoder* d) { delete d; }

extern "C" fd_decoder* fd_libraw_open(const char* path, fd_info* info, char* err, int err_len) {
    auto* d = new fd_decoder();
    d->raw = std::make_unique<LibRaw>();
    d->path = path;
    d->canonLog3 = hasExtension(d->path, "crm");
    configure(*d->raw, 0, d->canonLog3);
    int r = d->raw->open_file(path);
    if (r != LIBRAW_SUCCESS) {
        if (err && err_len > 0) std::snprintf(err, err_len, "LibRaw: %s", libraw_strerror(r));
        fd_libraw_close(d);
        return nullptr;
    }
    // Output size after demosaic and orientation, without decoding the frame yet.
    int w = 0, h = 0;
    d->raw->adjust_sizes_info_only();
    w = d->raw->imgdata.sizes.iwidth;
    h = d->raw->imgdata.sizes.iheight;
    if (d->raw->imgdata.sizes.flip & 4) std::swap(w, h);
    d->width = w;
    d->height = h;
    d->frames = d->raw->imgdata.idata.raw_count;
    if (d->frames < 1) d->frames = 1;

    info->width = w;
    info->height = h;
    info->fps = d->frames > 1 ? containerFrameRate(path) : 0;
    if (d->frames > 1 && info->fps <= 0) info->fps = 24;
    info->frame_count = d->frames;
    info->bit_depth = 16;
    std::snprintf(info->codec, sizeof info->codec, "%s %s RAW (LibRaw)", d->raw->imgdata.idata.make,
                  d->raw->imgdata.idata.model);
    return d;
}

extern "C" int fd_libraw_read(fd_decoder* d, int64_t index, uint16_t* rgba) {
    if (index < 0 || index >= d->frames) return 1;
    LibRaw& raw = *d->raw;
    raw.recycle();
    configure(raw, unsigned(index), d->canonLog3);
    if (raw.open_file(d->path.c_str()) != LIBRAW_SUCCESS) return -1;
    if (raw.unpack() != LIBRAW_SUCCESS) return -1;
    if (raw.dcraw_process() != LIBRAW_SUCCESS) return -1;
    int r = 0;
    libraw_processed_image_t* img = raw.dcraw_make_mem_image(&r);
    if (!img || r != LIBRAW_SUCCESS) return -1;
    int ok = -1;
    if (img->type == LIBRAW_IMAGE_BITMAP && img->bits == 16 && img->colors == 3 &&
        img->width == d->width && img->height == d->height) {
        const uint16_t* src = reinterpret_cast<const uint16_t*>(img->data);
        size_t n = size_t(img->width) * img->height;
        if (d->canonLog3) {
            const auto& lut = canonLog3Lut();
            const double s = kCrmExposure / 65535 * 16384;   // 16-bit XYZ -> scene linear -> LUT index
            for (size_t i = 0; i < n; i++) {
                double X = src[i * 3], Y = src[i * 3 + 1], Z = src[i * 3 + 2];
                for (int c = 0; c < 3; c++) {
                    double v = (kXyzToCinemaGamut[c][0] * X + kXyzToCinemaGamut[c][1] * Y + kXyzToCinemaGamut[c][2] * Z) * s;
                    rgba[i * 4 + c] = lut[size_t(std::fmin(std::fmax(v, 0.0), double(lut.size() - 1)) + 0.5)];
                }
                rgba[i * 4 + 3] = 65535;
            }
            LibRaw::dcraw_clear_mem(img);
            return 0;
        }
        for (size_t i = 0; i < n; i++) {
            rgba[i * 4 + 0] = src[i * 3 + 0];
            rgba[i * 4 + 1] = src[i * 3 + 1];
            rgba[i * 4 + 2] = src[i * 3 + 2];
            rgba[i * 4 + 3] = 65535;
        }
        ok = 0;
    }
    LibRaw::dcraw_clear_mem(img);
    return ok;
}
