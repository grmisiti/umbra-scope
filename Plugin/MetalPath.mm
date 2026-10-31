// GPU path of the Umbra Link plugin: runs on Resolve's own Metal command queue.
//
// Two kernels per render:
//   copy_through  — input buffer -> output buffer (the node is a pass-through)
//   compact       — nearest-neighbour downscale to RGBA 16-bit, rows top-down, into a shared buffer we own
// The compact buffer is read in the command buffer's completion handler, so Resolve's render never waits for
// the copy to the app.
#import <Metal/Metal.h>

#include <mutex>
#include <unordered_map>

#include "MetalPath.h"

static const char* kKernels = R"METAL(
#include <metal_stdlib>
using namespace metal;

struct Rect { int x1, y1, x2, y2; };

struct CopyArgs {
    Rect src;          // bounds of the source image (OFX pixel coordinates, y up)
    Rect dst;          // bounds of the destination image
    int srcStride;     // floats per source row
    int dstStride;     // floats per destination row
};

kernel void copy_through(const device float4* src [[buffer(0)]],
                         device float4* dst [[buffer(1)]],
                         constant CopyArgs& a [[buffer(2)]],
                         uint2 id [[thread_position_in_grid]]) {
    int w = a.dst.x2 - a.dst.x1, h = a.dst.y2 - a.dst.y1;
    if (int(id.x) >= w || int(id.y) >= h) return;
    int gx = a.dst.x1 + int(id.x), gy = a.dst.y1 + int(id.y);
    float4 v = float4(0.0);
    if (gx >= a.src.x1 && gx < a.src.x2 && gy >= a.src.y1 && gy < a.src.y2) {
        v = src[(gy - a.src.y1) * (a.srcStride / 4) + (gx - a.src.x1)];
    }
    dst[int(id.y) * (a.dstStride / 4) + int(id.x)] = v;
}

struct CompactArgs {
    int srcW, srcH;    // source image size
    int srcStride;     // floats per source row
    int outW, outH;    // compact size
    int video;         // map 0..1 to 10-bit legal range
};

kernel void compact(const device float4* src [[buffer(0)]],
                    device ushort4* out [[buffer(1)]],
                    constant CompactArgs& a [[buffer(2)]],
                    uint2 id [[thread_position_in_grid]]) {
    if (int(id.x) >= a.outW || int(id.y) >= a.outH) return;
    // OFX rows go bottom-up; the wire format is top-down.
    int sx = int((float(id.x) + 0.5) * float(a.srcW) / float(a.outW));
    int sy = a.srcH - 1 - int((float(id.y) + 0.5) * float(a.srcH) / float(a.outH));
    float4 p = clamp(src[sy * (a.srcStride / 4) + sx], 0.0, 1.0);
    if (a.video) p.rgb = (64.0 + p.rgb * 876.0) / 1023.0;
    out[int(id.y) * a.outW + int(id.x)] = ushort4(p * 65535.0 + 0.5);
}
)METAL";

namespace {

struct Pipelines {
    id<MTLComputePipelineState> copy;
    id<MTLComputePipelineState> compact;
};

std::mutex g_mutex;
std::unordered_map<void*, Pipelines> g_pipelines;  // keyed by MTLDevice

bool pipelinesFor(id<MTLDevice> device, Pipelines& out) {
    std::lock_guard<std::mutex> lock(g_mutex);
    auto it = g_pipelines.find((__bridge void*)device);
    if (it != g_pipelines.end()) { out = it->second; return true; }

    NSError* err = nil;
    MTLCompileOptions* opts = [MTLCompileOptions new];
    id<MTLLibrary> lib = [device newLibraryWithSource:@(kKernels) options:opts error:&err];
    if (!lib) { NSLog(@"UmbraLink: Metal compile failed: %@", err); return false; }
    Pipelines p;
    p.copy = [device newComputePipelineStateWithFunction:[lib newFunctionWithName:@"copy_through"] error:&err];
    p.compact = [device newComputePipelineStateWithFunction:[lib newFunctionWithName:@"compact"] error:&err];
    if (!p.copy || !p.compact) { NSLog(@"UmbraLink: pipeline failed: %@", err); return false; }
    // Keep the device's pipelines for the life of the process (Resolve keeps one queue per GPU).
    g_pipelines[(__bridge void*)device] = p;
    out = p;
    return true;
}

MTLSize groupsFor(id<MTLComputePipelineState> ps, int w, int h, MTLSize& perGroup) {
    NSUInteger tw = ps.threadExecutionWidth;
    NSUInteger th = MAX(1, ps.maxTotalThreadsPerThreadgroup / tw);
    perGroup = MTLSizeMake(tw, th, 1);
    return MTLSizeMake((w + tw - 1) / tw, (h + th - 1) / th, 1);
}

}  // namespace

bool UmbraLinkMetalRender(const MetalRenderJob& job) {
    id<MTLCommandQueue> queue = (__bridge id<MTLCommandQueue>)job.commandQueue;
    id<MTLBuffer> src = (__bridge id<MTLBuffer>)job.srcBuffer;
    id<MTLBuffer> dst = (__bridge id<MTLBuffer>)job.dstBuffer;
    if (!queue || !src || !dst) return false;

    Pipelines p;
    if (!pipelinesFor(queue.device, p)) return false;

    id<MTLCommandBuffer> cmd = [queue commandBuffer];
    cmd.label = @"UmbraLink";
    id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
    MTLSize perGroup;

    struct { int x1, y1, x2, y2; } srcR = {job.src.x1, job.src.y1, job.src.x2, job.src.y2},
                                   dstR = {job.dst.x1, job.dst.y1, job.dst.x2, job.dst.y2};
    struct { decltype(srcR) s, d; int srcStride, dstStride; } copyArgs = {srcR, dstR, job.srcRowBytes / 4, job.dstRowBytes / 4};
    [enc setComputePipelineState:p.copy];
    [enc setBuffer:src offset:0 atIndex:0];
    [enc setBuffer:dst offset:0 atIndex:1];
    [enc setBytes:&copyArgs length:sizeof copyArgs atIndex:2];
    MTLSize groups = groupsFor(p.copy, job.dst.x2 - job.dst.x1, job.dst.y2 - job.dst.y1, perGroup);
    [enc dispatchThreadgroups:groups threadsPerThreadgroup:perGroup];

    id<MTLBuffer> out = nil;
    if (job.outW > 0 && job.outH > 0) {
        const NSUInteger outBytes = NSUInteger(job.outW) * job.outH * 8;
        out = [queue.device newBufferWithLength:outBytes options:MTLResourceStorageModeShared];
        struct { int srcW, srcH, srcStride, outW, outH, video; } compactArgs = {
            job.src.x2 - job.src.x1, job.src.y2 - job.src.y1, job.srcRowBytes / 4, job.outW, job.outH, job.video ? 1 : 0};
        [enc setComputePipelineState:p.compact];
        [enc setBuffer:src offset:0 atIndex:0];
        [enc setBuffer:out offset:0 atIndex:1];
        [enc setBytes:&compactArgs length:sizeof compactArgs atIndex:2];
        groups = groupsFor(p.compact, job.outW, job.outH, perGroup);
        [enc dispatchThreadgroups:groups threadsPerThreadgroup:perGroup];
    }
    [enc endEncoding];

    if (out) {
        auto onReady = job.onReady;
        [cmd addCompletedHandler:^(id<MTLCommandBuffer> cb) {
            // An exception must not escape into Metal's completion thread (it would abort the host).
            try {
                if (cb.status == MTLCommandBufferStatusCompleted) {
                    onReady(static_cast<const uint16_t*>(out.contents), out.length);
                }
            } catch (...) {}
        }];
    }
    [cmd commit];
    return true;
}
