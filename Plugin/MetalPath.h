// Interface between the C++ plugin and its Objective-C++ Metal path.
#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>

struct MetalRect { int x1, y1, x2, y2; };

struct MetalRenderJob {
    void* commandQueue;   // id<MTLCommandQueue> from the host's render arguments
    const void* srcBuffer;  // id<MTLBuffer> of the source image
    void* dstBuffer;        // id<MTLBuffer> of the destination image
    MetalRect src, dst;     // image bounds
    int srcRowBytes, dstRowBytes;
    int outW, outH;         // compact size; 0 to skip publishing
    bool video;             // legal-range mapping
    // Called on a Metal completion thread with RGBA16 pixels, top-down.
    std::function<void(const uint16_t* pixels, size_t bytes)> onReady;
};

/// Encodes the pass-through copy and the compact downscale on the host's queue. Returns false if Metal setup failed.
bool UmbraLinkMetalRender(const MetalRenderJob& job);
