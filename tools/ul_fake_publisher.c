// Publishes synthetic frames on a Umbra Link endpoint, to test the app without Resolve.
// Usage: ul_fake_publisher [rgba16|rgba32f] [full|video] [seconds] [endpoint]
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <zmq.h>
#include "../Shared/umbralink_protocol.h"

static void pattern(float t, int x, int y, int w, int h, float rgb[3]) {
    float u = (float)x / (w - 1), v = (float)y / (h - 1);
    if (v < 0.5f) {  // 75% colour bars
        static const float bars[7][3] = {{.75,.75,.75},{.75,.75,0},{0,.75,.75},{0,.75,0},{.75,0,.75},{.75,0,0},{0,0,.75}};
        int i = (int)(u * 7); if (i > 6) i = 6;
        memcpy(rgb, bars[i], sizeof(float) * 3);
    } else if (v < 0.75f) {  // luma ramp
        rgb[0] = rgb[1] = rgb[2] = u;
    } else {  // moving hue sweep
        float hue = fmodf(u + t * 0.2f, 1.0f) * 6.f;
        rgb[0] = fminf(fmaxf(fabsf(hue - 3.f) - 1.f, 0.f), 1.f);
        rgb[1] = fminf(fmaxf(2.f - fabsf(hue - 2.f), 0.f), 1.f);
        rgb[2] = fminf(fmaxf(2.f - fabsf(hue - 4.f), 0.f), 1.f);
    }
}

int main(int argc, char** argv) {
    const char* fmt = argc > 1 ? argv[1] : "rgba16";
    int video = argc > 2 && !strcmp(argv[2], "video");
    double seconds = argc > 3 ? atof(argv[3]) : 10;
    char defaultEndpoint[256] = "";
    ul_endpoint(defaultEndpoint, sizeof defaultEndpoint);
    const char* endpoint = argc > 4 ? argv[4] : defaultEndpoint;
    const int w = 960, h = 540;

    void* ctx = zmq_ctx_new();
    void* pub = zmq_socket(ctx, ZMQ_PUB);
    int hwm = 4;
    zmq_setsockopt(pub, ZMQ_SNDHWM, &hwm, sizeof hwm);
    if (!strncmp(endpoint, "ipc://", 6)) unlink(endpoint + 6);
    if (zmq_bind(pub, endpoint)) { fprintf(stderr, "bind: %s\n", zmq_strerror(zmq_errno())); return 1; }

    const int is_float = !strcmp(fmt, "rgba32f");
    const uint32_t format = is_float ? UL_FORMAT_RGBA32F : UL_FORMAT_RGBA16;
    const size_t bpp = ul_bytes_per_pixel(format);
    unsigned char* buf = malloc((size_t)w * h * bpp);
    ul_frame_header hd; memset(&hd, 0, sizeof hd);
    hd.magic = UL_MAGIC; hd.version = UL_VERSION; hd.header_bytes = sizeof hd;
    hd.width = w; hd.height = h; hd.format = format; hd.fps = 24;
    hd.flags = video ? UL_FLAG_LEGAL_RANGE : 0;

    int frames = (int)(seconds * 24);
    for (int n = 0; n < frames; n++) {
        float t = n / 24.f;
        for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
            float c[3]; pattern(t, x, y, w, h, c);
            if (video) for (int k = 0; k < 3; k++) c[k] = (64.f + c[k] * 876.f) / 1023.f;
            size_t i = (size_t)y * w + x;
            if (is_float) { float* p = (float*)buf + i * 4; p[0] = c[0]; p[1] = c[1]; p[2] = c[2]; p[3] = 1; }
            else { uint16_t* p = (uint16_t*)buf + i * 4; for (int k = 0; k < 3; k++) p[k] = (uint16_t)(c[k] * 65535 + .5f); p[3] = 65535; }
        }
        hd.frame = n; hd.seconds = t;
        hd.timecode[2] = (uint8_t)(n / 24 % 60); hd.timecode[3] = (uint8_t)(n % 24);
        zmq_send(pub, &hd, sizeof hd, ZMQ_SNDMORE);
        zmq_send(pub, buf, (size_t)w * h * bpp, 0);
        usleep(1000000 / 24);
    }
    zmq_close(pub); zmq_ctx_term(ctx);
    return 0;
}
