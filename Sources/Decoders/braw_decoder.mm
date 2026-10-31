// Blackmagic RAW decoder, through the Blackmagic RAW SDK (loaded at run time from the app bundle, the SDK or
// DaVinci Resolve). Frames are processed to RGBA 16-bit with the clip's own gamma and gamut (as recorded in
// its metadata), like Resolve's "clip" decode settings.
#include <CoreFoundation/CoreFoundation.h>
#include <cstdio>
#include <cstring>
#include <string>

#include "BlackmagicRawAPI.h"
#include "file_decoder.h"

namespace {

// Receives the decoded image; FlushJobs() returns only after these callbacks have run.
class Callback : public IBlackmagicRawCallback {
public:
    uint16_t* target = nullptr;     // where ProcessComplete copies the image
    uint32_t width = 0, height = 0;
    HRESULT status = S_OK;

    void ReadComplete(IBlackmagicRawJob* readJob, HRESULT result, IBlackmagicRawFrame* frame) override {
        IBlackmagicRawJob* process = nullptr;
        if (result == S_OK) result = frame->SetResourceFormat(blackmagicRawResourceFormatRGBAU16);
        if (result == S_OK) result = frame->CreateJobDecodeAndProcessFrame(nullptr, nullptr, &process);
        if (result == S_OK) result = process->Submit();
        if (result != S_OK) {
            status = result;
            if (process) process->Release();
        }
        readJob->Release();
    }

    void ProcessComplete(IBlackmagicRawJob* job, HRESULT result, IBlackmagicRawProcessedImage* image) override {
        uint32_t w = 0, h = 0, size = 0;
        void* data = nullptr;
        if (result == S_OK) result = image->GetWidth(&w);
        if (result == S_OK) result = image->GetHeight(&h);
        if (result == S_OK) result = image->GetResourceSizeBytes(&size);
        if (result == S_OK) result = image->GetResource(&data);
        if (result == S_OK && w == width && h == height && size >= w * h * 8 && target) {
            std::memcpy(target, data, size_t(w) * h * 8);
        } else if (result == S_OK) {
            result = E_FAIL;
        }
        status = result;
        job->Release();
    }

    void DecodeComplete(IBlackmagicRawJob*, HRESULT) override {}
    void TrimProgress(IBlackmagicRawJob*, float) override {}
    void TrimComplete(IBlackmagicRawJob*, HRESULT) override {}
    void SidecarMetadataParseWarning(IBlackmagicRawClip*, CFStringRef, uint32_t, CFStringRef) override {}
    void SidecarMetadataParseError(IBlackmagicRawClip*, CFStringRef, uint32_t, CFStringRef) override {}
    void PreparePipelineComplete(void*, HRESULT) override {}
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID, LPVOID*) override { return E_NOTIMPL; }
    ULONG STDMETHODCALLTYPE AddRef() override { return 0; }
    ULONG STDMETHODCALLTYPE Release() override { return 0; }
};

// Directories that may hold BlackmagicRawAPI.framework, most specific first.
IBlackmagicRawFactory* makeFactory() {
    std::string bundled;
    if (CFURLRef url = CFBundleCopyPrivateFrameworksURL(CFBundleGetMainBundle())) {
        char buf[4096];
        if (CFURLGetFileSystemRepresentation(url, true, (UInt8*)buf, sizeof buf)) bundled = buf;
        CFRelease(url);
    }
    const char* dirs[] = {
        bundled.c_str(),
        "/Applications/Blackmagic RAW/Blackmagic RAW SDK/Mac/Libraries",
        "/Applications/DaVinci Resolve/DaVinci Resolve.app/Contents/Frameworks",
    };
    for (const char* dir : dirs) {
        if (!dir || !*dir) continue;
        CFStringRef path = CFStringCreateWithCString(nullptr, dir, kCFStringEncodingUTF8);
        IBlackmagicRawFactory* f = CreateBlackmagicRawFactoryInstanceFromPath(path);
        CFRelease(path);
        if (f) return f;
    }
    return nullptr;
}

}  // namespace

struct fd_decoder {
    int kind = 1;
    IBlackmagicRawFactory* factory = nullptr;
    IBlackmagicRaw* codec = nullptr;
    IBlackmagicRawClip* clip = nullptr;
    Callback callback;
};

extern "C" void fd_braw_close(fd_decoder* d);

extern "C" fd_decoder* fd_braw_open(const char* path, fd_info* info, char* err, int err_len) {
    auto fail = [&](const char* msg, fd_decoder* d) -> fd_decoder* {
        if (err && err_len > 0) std::snprintf(err, err_len, "%s", msg);
        fd_braw_close(d);
        return nullptr;
    };
    auto* d = new fd_decoder();
    d->factory = makeFactory();
    if (!d->factory) return fail("Blackmagic RAW SDK not found (install Blackmagic RAW or DaVinci Resolve)", d);
    if (d->factory->CreateCodec(&d->codec) != S_OK) return fail("could not create the BRAW codec", d);
    CFStringRef clipPath = CFStringCreateWithCString(nullptr, path, kCFStringEncodingUTF8);
    HRESULT r = d->codec->OpenClip(clipPath, &d->clip);
    CFRelease(clipPath);
    if (r != S_OK) return fail("could not open the BRAW clip", d);
    if (d->codec->SetCallback(&d->callback) != S_OK) return fail("could not set the BRAW callback", d);

    uint32_t w = 0, h = 0;
    float fps = 0;
    uint64_t frames = 0;
    d->clip->GetWidth(&w);
    d->clip->GetHeight(&h);
    d->clip->GetFrameRate(&fps);
    d->clip->GetFrameCount(&frames);
    d->callback.width = w;
    d->callback.height = h;
    info->width = int(w);
    info->height = int(h);
    info->fps = fps;
    info->frame_count = int64_t(frames);
    info->bit_depth = 16;
    std::snprintf(info->codec, sizeof info->codec, "Blackmagic RAW");
    return d;
}

extern "C" int fd_braw_read(fd_decoder* d, int64_t index, uint16_t* rgba) {
    uint64_t frames = 0;
    d->clip->GetFrameCount(&frames);
    if (index < 0 || uint64_t(index) >= frames) return 1;
    IBlackmagicRawJob* job = nullptr;
    if (d->clip->CreateJobReadFrame(uint64_t(index), &job) != S_OK) return -1;
    d->callback.target = rgba;
    d->callback.status = S_OK;
    if (job->Submit() != S_OK) {
        job->Release();
        return -1;
    }
    d->codec->FlushJobs();   // blocks until ReadComplete and ProcessComplete have run
    d->callback.target = nullptr;
    return d->callback.status == S_OK ? 0 : -1;
}

extern "C" void fd_braw_close(fd_decoder* d) {
    if (!d) return;
    if (d->clip) d->clip->Release();
    if (d->codec) d->codec->Release();
    if (d->factory) d->factory->Release();
    delete d;
}
