// Subscribes to the Umbra Link stream and prints each frame header (see ../Shared/umbralink_protocol.h).
// Usage: ul_probe [endpoint] [--dump <file.raw>] [--count N]   (N frames, default 20; 0 = until killed)
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zmq.h>
#include "../Shared/umbralink_protocol.h"

int main(int argc, char** argv) {
    char endpoint[256] = "";
    ul_endpoint(endpoint, sizeof endpoint);
    const char* dump = NULL;
    int count = 20;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--dump") && i + 1 < argc) dump = argv[++i];
        else if (!strcmp(argv[i], "--count") && i + 1 < argc) count = atoi(argv[++i]);
        else snprintf(endpoint, sizeof endpoint, "%s", argv[i]);
    }
    setvbuf(stdout, NULL, _IOLBF, 0);
    void* ctx = zmq_ctx_new();
    void* sub = zmq_socket(ctx, ZMQ_SUB);
    int timeout = 5000;
    zmq_setsockopt(sub, ZMQ_RCVTIMEO, &timeout, sizeof timeout);
    zmq_setsockopt(sub, ZMQ_SUBSCRIBE, "", 0);
    if (zmq_connect(sub, endpoint) != 0) { fprintf(stderr, "connect %s: %s\n", endpoint, zmq_strerror(zmq_errno())); return 1; }
    printf("listening on %s\n", endpoint);

    long long last = -1;
    int n = 0;
    while (count <= 0 || n < count) {
        zmq_msg_t part; zmq_msg_init(&part);
        if (zmq_msg_recv(&part, sub, 0) < 0) { printf("timeout (no frames for 5 s)\n"); zmq_msg_close(&part); continue; }
        ul_frame_header h; memset(&h, 0, sizeof h);
        size_t sizes[4] = {0}; int nparts = 0;
        unsigned char* pixels = NULL;
        for (;;) {
            size_t sz = zmq_msg_size(&part);
            if (nparts < 4) sizes[nparts] = sz;
            if (nparts == 0 && sz >= sizeof h) memcpy(&h, zmq_msg_data(&part), sizeof h);
            if (nparts == 1 && sz > 0) { pixels = malloc(sz); memcpy(pixels, zmq_msg_data(&part), sz); }
            nparts++;
            int more = zmq_msg_more(&part);
            zmq_msg_close(&part);
            if (!more) break;
            zmq_msg_init(&part);
            zmq_msg_recv(&part, sub, 0);
        }
        // A frame that isn't the previous one + 1 is a seek, a repeat (cached frame re-sent on subscribe) or a drop.
        const long long f = (long long)h.frame;
        const char* note = last < 0 || f == last + 1 ? "" : f == last ? "  (repeat)" : "  (jump)";
        last = f;
        printf("#%d parts=%d sizes=[%zu,%zu] magic=%s v%u %ux%u format=%u flags=0x%x frame=%llu t=%.3f fps=%.3f "
               "tc=%02u:%02u:%02u:%02u%s\n", n, nparts, sizes[0], sizes[1], h.magic == UL_MAGIC ? "ok" : "BAD", h.version,
               h.width, h.height, h.format, h.flags, (unsigned long long)h.frame, h.seconds, h.fps,
               h.timecode[0], h.timecode[1], h.timecode[2], h.timecode[3], note);
        if (pixels && dump) {
            FILE* f = fopen(dump, "wb"); fwrite(pixels, 1, sizes[1], f); fclose(f);
            printf("   dumped %zu bytes to %s\n", sizes[1], dump);
            dump = NULL;
        }
        free(pixels);
        n++;
    }
    printf("stopped after %d frames (--count %d; use --count 0 to keep listening)\n", n, count);
    zmq_close(sub); zmq_ctx_term(ctx);
    return 0;
}
