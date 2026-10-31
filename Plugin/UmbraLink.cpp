// Umbra Link — OFX pass-through node that publishes a downscaled copy of its input to Umbra Scope.
//
// Transport and header follow ../Shared/umbralink_protocol.h: ZeroMQ XPUB on a socket in the user's temp folder,
// 2-part message [ul_frame_header][pixels]. Pixels are RGBA 16-bit unsigned (0..65535), rows top-down,
// nearest-neighbour downscale to at most `Max width` columns.
//
// Rendering runs on Resolve's Metal queue when the host enables it (MetalPath.mm), on the CPU otherwise.
// The last frame is kept and re-sent whenever the app (re)subscribes, so a paused frame can still be measured.
#include <algorithm>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <vector>

#include <unistd.h>
#include <zmq.h>

#include "ofxsImageEffect.h"
#include "ofxsMultiThread.h"
#include "../Shared/umbralink_protocol.h"
#include "MetalPath.h"

#define kPluginName "Umbra Link"
#define kPluginGrouping "Scopes"
#define kPluginDescription "Sends the node's input to Umbra Scope on this Mac. The image passes through unchanged."
#define kPluginIdentifier "com.grmisiti.umbrascope.UmbraLink"
#define kPluginVersionMajor 1
#define kPluginVersionMinor 2

#define kParamEnabled "enabled"
#define kParamMaxWidth "maxWidth"
#define kParamRange "range"

static const int kMaxWidths[] = {480, 960, 1280, 1920};
static const int kDefaultMaxWidth = 3;  // 1920 px, the full size

template <class T>
static T clampv(T v, T lo, T hi) { return v < lo ? lo : (v > hi ? hi : v); }

// ---------------------------------------------------------------------------
// Publisher: one ZeroMQ XPUB socket shared by every node instance in the host process.
// XPUB (instead of PUB) lets us see subscriptions: when the app connects, it gets the last frame right away.

class Publisher {
public:
    static Publisher& get() {
        // Deliberately leaked: a static instance would destroy the joinable watcher thread at host exit
        // (std::terminate) when the host quits without unloading the plugin.
        static Publisher* instance = new Publisher;
        return *instance;
    }

    void send(const ul_frame_header& h, const void* pixels, size_t size) {
        // A Metal completion handler can still fire after the host unloaded the plugin: don't reopen the socket then.
        if (unloaded_) return;
        std::lock_guard<std::mutex> lock(mutex_);
        if (unloaded_) return;
        cacheHeader_ = h;
        cachePixels_.assign(static_cast<const uint8_t*>(pixels), static_cast<const uint8_t*>(pixels) + size);
        hasCache_ = true;
        if (ensureSocket()) sendCacheLocked();
    }

    /// Called when the host loads the plugin (again, after an unload).
    void load() { unloaded_ = false; }

    void shutdown() {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            unloaded_ = true;
            stopping_ = true;
        }
        wake_.notify_all();
        if (watcher_.joinable()) watcher_.join();
        std::lock_guard<std::mutex> lock(mutex_);
        if (socket_) { int linger = 0; zmq_setsockopt(socket_, ZMQ_LINGER, &linger, sizeof linger); zmq_close(socket_); socket_ = nullptr; }
        if (ctx_) { zmq_ctx_term(ctx_); ctx_ = nullptr; }
        failed_ = false;
        stopping_ = false;
        hasCache_ = false;
    }

private:
    bool ensureSocket() {
        if (socket_) return true;
        if (failed_) return false;
        ctx_ = zmq_ctx_new();
        socket_ = zmq_socket(ctx_, ZMQ_XPUB);
        int hwm = 4, linger = 0, verbose = 1;
        zmq_setsockopt(socket_, ZMQ_SNDHWM, &hwm, sizeof hwm);
        zmq_setsockopt(socket_, ZMQ_LINGER, &linger, sizeof linger);
        // Deliver every subscription, even repeated ones, so each reconnecting app gets the cached frame.
        zmq_setsockopt(socket_, ZMQ_XPUB_VERBOSE, &verbose, sizeof verbose);
        char endpoint[256];
        int ok = ul_endpoint(endpoint, sizeof endpoint);
        const char* path = endpoint + sizeof("ipc://") - 1;
        // Remove a stale socket file left by a crashed host, but never one another live host is bound to
        // (two Resolve instances): stealing it would silently cut that host off from the app.
        if (ok == 0) {
            const int state = socketFileState(path);
            if (state == 1) ok = -1;
            else if (state == 0) unlink(path);
        }
        if (ok != 0 || zmq_bind(socket_, endpoint) != 0) {
            zmq_close(socket_); socket_ = nullptr;
            zmq_ctx_term(ctx_); ctx_ = nullptr;
            failed_ = true;  // don't retry on every frame
            return false;
        }
        chmod(path, 0600);  // owner only, whatever umask the host runs with
        watcher_ = std::thread([this] { watchSubscriptions(); });
        return true;
    }

    /// 1 = something accepts connections on `path`, 0 = stale or missing (safe to unlink), -1 = unknown.
    static int socketFileState(const char* path) {
        sockaddr_un addr{};
        addr.sun_family = AF_UNIX;
        if (std::strlen(path) >= sizeof addr.sun_path) return -1;
        std::strncpy(addr.sun_path, path, sizeof addr.sun_path - 1);
        const int fd = socket(AF_UNIX, SOCK_STREAM, 0);
        if (fd < 0) return -1;
        const int rc = connect(fd, reinterpret_cast<sockaddr*>(&addr), sizeof addr);
        const int err = errno;
        close(fd);
        if (rc == 0) return 1;
        return (err == ECONNREFUSED || err == ENOENT) ? 0 : -1;
    }

    // PUB never blocks: frames beyond the high-water mark are dropped, which keeps Resolve's render fast.
    void sendCacheLocked() {
        if (!hasCache_) return;
        if (zmq_send(socket_, &cacheHeader_, sizeof cacheHeader_, ZMQ_SNDMORE | ZMQ_DONTWAIT) < 0) return;
        zmq_send(socket_, cachePixels_.data(), cachePixels_.size(), ZMQ_DONTWAIT);
    }

    // The socket is only touched under the mutex, so this thread polls instead of blocking in recv.
    void watchSubscriptions() {
        std::unique_lock<std::mutex> lock(mutex_);
        while (!stopping_) {
            bool subscribed = false;
            char msg[256];
            int n;
            while ((n = zmq_recv(socket_, msg, sizeof msg, ZMQ_DONTWAIT)) > 0) {
                if (msg[0] == 1) subscribed = true;  // 1 = subscribe, 0 = unsubscribe
            }
            if (subscribed) sendCacheLocked();
            wake_.wait_for(lock, std::chrono::milliseconds(100));
        }
    }

    std::mutex mutex_;
    std::condition_variable wake_;
    std::thread watcher_;
    void* ctx_ = nullptr;
    void* socket_ = nullptr;
    bool failed_ = false;
    bool stopping_ = false;
    bool hasCache_ = false;
    std::atomic<bool> unloaded_{false};
    ul_frame_header cacheHeader_{};
    std::vector<uint8_t> cachePixels_;
};

// ---------------------------------------------------------------------------

class UmbraLinkPlugin : public OFX::ImageEffect {
public:
    explicit UmbraLinkPlugin(OfxImageEffectHandle handle) : ImageEffect(handle) {
        dstClip_ = fetchClip(kOfxImageEffectOutputClipName);
        srcClip_ = fetchClip(kOfxImageEffectSimpleSourceClipName);
        enabled_ = fetchBooleanParam(kParamEnabled);
        maxWidth_ = fetchChoiceParam(kParamMaxWidth);
        range_ = fetchChoiceParam(kParamRange);
    }

    void render(const OFX::RenderArguments& args) override {
        std::unique_ptr<OFX::Image> dst(dstClip_->fetchImage(args.time));
        std::unique_ptr<OFX::Image> src(srcClip_->fetchImage(args.time));
        if (!dst || !src) OFX::throwSuiteStatusException(kOfxStatFailed);
        if (src->getPixelDepth() != OFX::eBitDepthFloat || src->getPixelComponents() != OFX::ePixelComponentRGBA ||
            dst->getPixelDepth() != OFX::eBitDepthFloat || dst->getPixelComponents() != OFX::ePixelComponentRGBA) {
            OFX::throwSuiteStatusException(kOfxStatErrImageFormat);
        }

        // Only full-resolution renders of the viewer are worth sending (skip thumbnails / proxy scales).
        const bool publish = enabled_->getValueAtTime(args.time) && args.renderScale.x == 1.0 && args.renderScale.y == 1.0;
        int outW = 0, outH = 0;
        if (publish) compactSize(*src, args.time, outW, outH);
        const ul_frame_header hdr = publish ? makeHeader(args.time, outW, outH) : ul_frame_header{};
        const bool legal = (hdr.flags & UL_FLAG_LEGAL_RANGE) != 0;

#ifdef __APPLE__
        if (args.isEnabledMetalRender) {
            MetalRenderJob job;
            job.commandQueue = args.pMetalCmdQ;
            job.srcBuffer = src->getPixelData();
            job.dstBuffer = dst->getPixelData();
            const OfxRectI sb = src->getBounds(), db = dst->getBounds();
            job.src = {sb.x1, sb.y1, sb.x2, sb.y2};
            job.dst = {db.x1, db.y1, db.x2, db.y2};
            job.srcRowBytes = src->getRowBytes();
            job.dstRowBytes = dst->getRowBytes();
            job.outW = outW;
            job.outH = outH;
            job.video = legal;
            job.onReady = [hdr](const uint16_t* pixels, size_t bytes) { Publisher::get().send(hdr, pixels, bytes); };
            if (!UmbraLinkMetalRender(job)) OFX::throwSuiteStatusException(kOfxStatFailed);
            return;
        }
#endif
        copyThrough(*src, *dst, args.renderWindow);
        if (publish) {
            std::vector<uint16_t> buf(size_t(outW) * outH * 4);
            compactCPU(*src, outW, outH, legal, buf.data());
            Publisher::get().send(hdr, buf.data(), buf.size() * sizeof(uint16_t));
        }
    }

private:
    void compactSize(const OFX::Image& src, double time, int& w, int& h) {
        const OfxRectI b = src.getBounds();
        const int W = b.x2 - b.x1, H = b.y2 - b.y1;
        if (W < 16 || H < 16) { w = h = 0; return; }
        int choice = kDefaultMaxWidth;
        maxWidth_->getValueAtTime(time, choice);
        const double par = srcClip_->getPixelAspectRatio();
        w = std::min(W, kMaxWidths[clampv(choice, 0, 3)]);
        h = std::max(1, int(std::lround(double(w) * H / (W * (par > 0 ? par : 1.0)))));
    }

    ul_frame_header makeHeader(double time, int w, int h) {
        int rangeChoice = 0;
        range_->getValueAtTime(time, rangeChoice);
        ul_frame_header hdr{};
        hdr.magic = UL_MAGIC;
        hdr.version = UL_VERSION;
        hdr.header_bytes = sizeof hdr;
        hdr.width = uint32_t(w);
        hdr.height = uint32_t(h);
        hdr.format = UL_FORMAT_RGBA16;
        hdr.flags = UL_FLAG_DOWNSCALED | (rangeChoice == 1 ? UL_FLAG_LEGAL_RANGE : 0);
        const double fps = srcClip_->getFrameRate();
        hdr.fps = fps > 0 ? fps : 0;
        hdr.seconds = fps > 0 ? time / fps : time;
        hdr.frame = uint64_t(std::max(0.0, time));
        if (fps > 0) {
            const int ifps = std::max(1, int(std::lround(fps)));  // fps < 0.5 would round to 0
            const long long f = (long long)std::llround(std::max(0.0, time));
            hdr.timecode[0] = uint8_t((f / (ifps * 3600)) % 24);
            hdr.timecode[1] = uint8_t((f / (ifps * 60)) % 60);
            hdr.timecode[2] = uint8_t((f / ifps) % 60);
            hdr.timecode[3] = uint8_t(f % ifps);
        }
        return hdr;
    }

    static void copyThrough(const OFX::Image& src, OFX::Image& dst, const OfxRectI& win) {
        const OfxRectI sb = src.getBounds();
        for (int y = win.y1; y < win.y2; ++y) {
            float* d = static_cast<float*>(dst.getPixelAddress(win.x1, y));
            if (!d) continue;
            int x = win.x1;
            // Pixels outside the source bounds become transparent black.
            for (; x < std::min(win.x2, sb.x1); ++x, d += 4) std::fill(d, d + 4, 0.f);
            const int xe = std::min(win.x2, sb.x2);
            if (y >= sb.y1 && y < sb.y2 && x < xe) {
                const float* s = static_cast<const float*>(src.getPixelAddress(x, y));
                std::memcpy(d, s, sizeof(float) * 4 * (xe - x));
                d += 4 * (xe - x);
                x = xe;
            }
            for (; x < win.x2; ++x, d += 4) std::fill(d, d + 4, 0.f);
        }
    }

    // Same sampling as the Metal `compact` kernel.
    static void compactCPU(const OFX::Image& src, int w, int h, bool video, uint16_t* out) {
        const OfxRectI b = src.getBounds();
        const int W = b.x2 - b.x1, H = b.y2 - b.y1;
        for (int y = 0; y < h; ++y) {
            // OFX rows go bottom-up; the wire format is top-down.
            const int sy = b.y2 - 1 - int((y + 0.5) * H / h);
            const float* row = static_cast<const float*>(src.getPixelAddress(b.x1, sy));
            uint16_t* o = out + size_t(y) * w * 4;
            for (int x = 0; x < w; ++x) {
                const float* p = row + 4 * int((x + 0.5) * W / w);
                for (int c = 0; c < 4; ++c) {
                    float v = clampv(p[c], 0.f, 1.f);
                    if (video && c < 3) v = (64.f + v * 876.f) / 1023.f;  // 10-bit legal range, kept in 16-bit
                    o[x * 4 + c] = uint16_t(v * 65535.f + 0.5f);
                }
            }
        }
    }

    OFX::Clip* dstClip_;
    OFX::Clip* srcClip_;
    OFX::BooleanParam* enabled_;
    OFX::ChoiceParam* maxWidth_;
    OFX::ChoiceParam* range_;
};

// ---------------------------------------------------------------------------

mDeclarePluginFactory(UmbraLinkFactory, { Publisher::get().load(); }, { Publisher::get().shutdown(); });

void UmbraLinkFactory::describe(OFX::ImageEffectDescriptor& d) {
    d.setLabels(kPluginName, kPluginName, kPluginName);
    d.setPluginGrouping(kPluginGrouping);
    d.setPluginDescription(kPluginDescription);
    // The icon is Contents/Resources/<plugin identifier>.png (see build_plugin.sh). Do not also set kOfxPropIcon here:
    // Resolve rejects it, describe then fails, and the support library crashes the host when it unloads the plugin.
    d.addSupportedContext(OFX::eContextFilter);
    d.addSupportedContext(OFX::eContextGeneral);
    d.addSupportedBitDepth(OFX::eBitDepthFloat);
    d.setSingleInstance(false);
    d.setHostFrameThreading(false);
    d.setSupportsMultiResolution(false);
    d.setSupportsTiles(false);
    d.setTemporalClipAccess(false);
    d.setRenderTwiceAlways(false);
    d.setSupportsMultipleClipPARs(false);
    d.setRenderThreadSafety(OFX::eRenderInstanceSafe);
#ifdef __APPLE__
    d.setSupportsMetalRender(true);  // Resolve then hands us MTLBuffers and its command queue
#endif
}

void UmbraLinkFactory::describeInContext(OFX::ImageEffectDescriptor& d, OFX::ContextEnum) {
    OFX::ClipDescriptor* src = d.defineClip(kOfxImageEffectSimpleSourceClipName);
    src->addSupportedComponent(OFX::ePixelComponentRGBA);
    src->setSupportsTiles(false);
    OFX::ClipDescriptor* dst = d.defineClip(kOfxImageEffectOutputClipName);
    dst->addSupportedComponent(OFX::ePixelComponentRGBA);
    dst->setSupportsTiles(false);

    OFX::PageParamDescriptor* page = d.definePageParam("Controls");

    OFX::BooleanParamDescriptor* en = d.defineBooleanParam(kParamEnabled);
    en->setLabels("Send to Scopes", "Send to Scopes", "Send to Scopes");
    en->setHint("Publish this node's input to the Scopes app.");
    en->setDefault(true);
    en->setAnimates(false);
    page->addChild(*en);

    OFX::ChoiceParamDescriptor* mw = d.defineChoiceParam(kParamMaxWidth);
    mw->setLabels("Max width", "Max width", "Max width");
    mw->setHint("Width of the copy sent to the app. Larger is more precise but costs more per frame.");
    for (int v : kMaxWidths) mw->appendOption(std::to_string(v) + " px");
    mw->setDefault(kDefaultMaxWidth);
    mw->setAnimates(false);
    page->addChild(*mw);

    OFX::ChoiceParamDescriptor* rg = d.defineChoiceParam(kParamRange);
    rg->setLabels("Signal range", "Signal range", "Signal range");
    rg->setHint("Full sends node values as-is. Video maps 0-1 to legal 64-940 (10-bit) like an SDI output.");
    rg->appendOption("Full");
    rg->appendOption("Video (legal)");
    rg->setDefault(0);
    rg->setAnimates(false);
    page->addChild(*rg);
}

OFX::ImageEffect* UmbraLinkFactory::createInstance(OfxImageEffectHandle handle, OFX::ContextEnum) {
    return new UmbraLinkPlugin(handle);
}

namespace OFX {
namespace Plugin {
void getPluginIDs(OFX::PluginFactoryArray& ids) {
    static UmbraLinkFactory factory(kPluginIdentifier, kPluginVersionMajor, kPluginVersionMinor);
    ids.push_back(&factory);
}
}  // namespace Plugin
}  // namespace OFX
