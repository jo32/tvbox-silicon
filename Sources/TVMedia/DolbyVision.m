#include "TVMedia.h"

#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <math.h>

#if !__has_feature(objc_arc)
#error "DolbyVision.m is built with ARC"
#endif

// Dolby Vision 5 to BT.2020 PQ: the base layer's samples are reshaped by the frame's RPU (a curve per component, in
// pieces that are polynomials or, for chroma, a regression on all three components), give PQ-coded LMS by the RPU's
// matrix, then linear BT.2020 RGB. The steps and their order are libplacebo's (src/shaders/colorspace.c and
// src/colorspace.c, LGPL-2.1, by Niklas Haas): pl_shader_dovi_reshape, then pl_color_repr_decode for
// PL_COLOR_SYSTEM_DOLBYVISION. VideoToolbox then maps the BT.2020 PQ picture to SDR as it does HDR10.

// SMPTE ST 2084.
#define PQ_M1 0.1593017578125f
#define PQ_M2 78.84375f
#define PQ_C1 0.8359375f
#define PQ_C2 18.8515625f
#define PQ_C3 18.6875f

static float pq_eotf(float x) {
    x = powf(fminf(fmaxf(x, 0), 1), 1 / PQ_M2);
    x = fmaxf(x - PQ_C1, 0) / (PQ_C2 - PQ_C3 * x);
    return powf(x, 1 / PQ_M1);
}

static float pq_oetf(float x) {
    x = powf(fmaxf(x, 0), PQ_M1);
    return powf((PQ_C1 + PQ_C2 * x) / (1 + PQ_C3 * x), PQ_M2);
}

static float reshape(const TVMReshaping *m, int c, const float sig[3]) {
    int pieces = m->pieces[c];
    if (pieces <= 0) return sig[c];
    float s = sig[c];
    int i = 0;
    while (i < pieces - 1 && s >= m->pivots[c][i + 1]) i++;
    float r;
    if (m->method[c][i] == 0) {
        const float *p = m->poly[c][i];
        r = (p[2] * s + p[1]) * s + p[0];
    } else {
        const float cross[4] = {sig[0] * sig[1], sig[0] * sig[2], sig[1] * sig[2], sig[0] * sig[1] * sig[2]};
        float a[3] = {sig[0], sig[1], sig[2]}, b[4] = {cross[0], cross[1], cross[2], cross[3]};
        r = m->mmrConstant[c][i];
        for (int k = 0; k < m->order[c][i]; k++) {
            const float *w = m->mmr[c][i][k];
            r += w[0] * a[0] + w[1] * a[1] + w[2] * a[2] + w[3] * b[0] + w[4] * b[1] + w[5] * b[2] + w[6] * b[3];
            for (int j = 0; j < 3; j++) a[j] *= sig[j];
            for (int j = 0; j < 4; j++) b[j] *= cross[j];
        }
    }
    return fminf(fmaxf(r, 0), 1);
}

void tvm_dovi_pixel(const TVMReshaping *m, const float ycc[3], float rgb[3]) {
    // Every component is held within its own curve's bounds, also where another one's regression reads it.
    float sig[3], v[3], lms[3];
    for (int c = 0; c < 3; c++) {
        float lo = m->pieces[c] > 0 ? m->pivots[c][0] : 0, hi = m->pieces[c] > 0 ? m->pivots[c][m->pieces[c]] : 1;
        sig[c] = fminf(fmaxf(ycc[c], lo), hi);
    }
    for (int c = 0; c < 3; c++) v[c] = reshape(m, c, sig) - m->offset[c];
    for (int i = 0; i < 3; i++) lms[i] = pq_eotf(m->toLMS[i * 3] * v[0] + m->toLMS[i * 3 + 1] * v[1] + m->toLMS[i * 3 + 2] * v[2]);
    for (int i = 0; i < 3; i++) rgb[i] = pq_oetf(m->toRGB[i * 3] * lms[0] + m->toRGB[i * 3 + 1] * lms[1] + m->toRGB[i * 3 + 2] * lms[2]);
}

// MARK: - On the GPU

/// The same steps as above, one thread per 2×2 pixels of the target: each pixel is sampled from the source at its own
/// place (a picture twice as big is averaged, 2×2 into 1), its chroma averaged into the target's one sample.
static NSString *const kernelSource = @
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"struct Mapping {\n"
"    int pieces[3]; float pivots[3][9]; int method[3][8]; int order[3][8]; float poly[3][8][3];\n"
"    float mmrConstant[3][8]; float mmr[3][8][3][7]; float offset[3]; float toLMS[9]; float toRGB[9];\n"
"};\n"
"constant float M1 = 0.1593017578125, M2 = 78.84375, C1 = 0.8359375, C2 = 18.8515625, C3 = 18.6875;\n"
"static float3 pq_eotf(float3 x) {\n"
"    x = pow(clamp(x, 0.0, 1.0), 1.0 / M2);\n"
"    x = max(x - C1, 0.0) / (C2 - C3 * x);\n"
"    return pow(x, 1.0 / M1);\n"
"}\n"
"static float3 pq_oetf(float3 x) {\n"
"    x = pow(max(x, 0.0), M1);\n"
"    return pow((C1 + C2 * x) / (1.0 + C3 * x), M2);\n"
"}\n"
"static float reshape(constant Mapping &m, int c, float3 sig) {\n"
"    int pieces = m.pieces[c];\n"
"    if (pieces <= 0) return sig[c];\n"
"    float s = sig[c];\n"
"    int i = 0;\n"
"    while (i < pieces - 1 && s >= m.pivots[c][i + 1]) i++;\n"
"    float r;\n"
"    if (m.method[c][i] == 0) {\n"
"        r = (m.poly[c][i][2] * s + m.poly[c][i][1]) * s + m.poly[c][i][0];\n"
"    } else {\n"
"        float4 cross = float4(sig.x * sig.y, sig.x * sig.z, sig.y * sig.z, sig.x * sig.y * sig.z);\n"
"        float3 a = sig; float4 b = cross;\n"
"        r = m.mmrConstant[c][i];\n"
"        for (int k = 0; k < m.order[c][i]; k++) {\n"
"            constant float *w = m.mmr[c][i][k];\n"
"            r += dot(float3(w[0], w[1], w[2]), a) + dot(float4(w[3], w[4], w[5], w[6]), b);\n"
"            a *= sig; b *= cross;\n"
"        }\n"
"    }\n"
"    return clamp(r, 0.0, 1.0);\n"
"}\n"
"static float3 pixel(constant Mapping &m, float3 ycc) {\n"
"    float3 lo, hi;\n"
"    for (int c = 0; c < 3; c++) {\n"
"        lo[c] = m.pieces[c] > 0 ? m.pivots[c][0] : 0.0;\n"
"        hi[c] = m.pieces[c] > 0 ? m.pivots[c][m.pieces[c]] : 1.0;\n"
"    }\n"
"    float3 sig = clamp(ycc, lo, hi);\n"
"    float3 v = float3(reshape(m, 0, sig), reshape(m, 1, sig), reshape(m, 2, sig)) - float3(m.offset[0], m.offset[1], m.offset[2]);\n"
"    float3 lms = pq_eotf(float3(dot(float3(m.toLMS[0], m.toLMS[1], m.toLMS[2]), v),\n"
"                                dot(float3(m.toLMS[3], m.toLMS[4], m.toLMS[5]), v),\n"
"                                dot(float3(m.toLMS[6], m.toLMS[7], m.toLMS[8]), v)));\n"
"    return pq_oetf(float3(dot(float3(m.toRGB[0], m.toRGB[1], m.toRGB[2]), lms),\n"
"                          dot(float3(m.toRGB[3], m.toRGB[4], m.toRGB[5]), lms),\n"
"                          dot(float3(m.toRGB[6], m.toRGB[7], m.toRGB[8]), lms)));\n"
"}\n"
"kernel void compose(texture2d<float, access::sample> lumaIn [[texture(0)]],\n"
"                    texture2d<float, access::sample> chromaIn [[texture(1)]],\n"
"                    texture2d<float, access::write> lumaOut [[texture(2)]],\n"
"                    texture2d<float, access::write> chromaOut [[texture(3)]],\n"
"                    constant Mapping &m [[buffer(0)]], constant float &scale [[buffer(1)]],\n"
"                    uint2 at [[thread_position_in_grid]]) {\n"
"    if (at.x >= chromaOut.get_width() || at.y >= chromaOut.get_height()) return;\n"
"    constexpr sampler bilinear(coord::normalized, filter::linear, address::clamp_to_edge);\n"
"    float2 size = float2(lumaOut.get_width(), lumaOut.get_height());\n"
"    float2 chroma = 0.0;\n"
"    for (uint dy = 0; dy < 2; dy++) {\n"
"        for (uint dx = 0; dx < 2; dx++) {\n"
"            uint2 p = at * 2 + uint2(dx, dy);\n"
"            float2 uv = (float2(p) + 0.5) / size;\n"
"            float3 ycc = float3(lumaIn.sample(bilinear, uv).r, chromaIn.sample(bilinear, uv).rg) * scale;\n"
"            float3 rgb = pixel(m, ycc);\n"
"            float y = dot(rgb, float3(0.2627, 0.6780, 0.0593));\n"
"            chroma += float2((rgb.b - y) / 1.8814, (rgb.r - y) / 1.4746);\n"
"            if (p.x < lumaOut.get_width() && p.y < lumaOut.get_height())\n"
"                lumaOut.write(float4(clamp(round(64.0 + 876.0 * y), 0.0, 1023.0) * (64.0 / 65535.0)), p);\n"
"        }\n"
"    }\n"
"    float2 c = clamp(round(512.0 + 896.0 * chroma * 0.25), 0.0, 1023.0) * (64.0 / 65535.0);\n"
"    chromaOut.write(float4(c, 0.0, 0.0), at);\n"
"}\n";

/// The compiled kernel, made once (the first Dolby Vision picture pays for it, tens of milliseconds).
static id<MTLComputePipelineState> pipeline(id<MTLDevice> *device) {
    static id<MTLDevice> shared;
    static id<MTLComputePipelineState> state;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = MTLCreateSystemDefaultDevice();
        if (!shared) return;
        NSError *error = nil;
        MTLCompileOptions *options = [MTLCompileOptions new];
        id<MTLLibrary> library = [shared newLibraryWithSource:kernelSource options:options error:&error];
        id<MTLFunction> function = [library newFunctionWithName:@"compose"];
        if (function) state = [shared newComputePipelineStateWithFunction:function error:&error];
        if (!state) NSLog(@"TVMedia: Dolby Vision kernel failed: %@", error);
    });
    *device = shared;
    return state;
}

@interface TVMComposerObject : NSObject
@property(nonatomic) id<MTLCommandQueue> queue;
@property(nonatomic) CVMetalTextureCacheRef cache;
@end

@implementation TVMComposerObject
- (void)dealloc {
    if (_cache) CFRelease(_cache);
}
@end

TVMComposer *tvm_composer_create(void) {
    id<MTLDevice> device = nil;
    if (!pipeline(&device)) return NULL;
    TVMComposerObject *composer = [TVMComposerObject new];
    composer.queue = [device newCommandQueue];
    CVMetalTextureCacheRef cache = NULL;
    if (!composer.queue || CVMetalTextureCacheCreate(NULL, NULL, device, NULL, &cache) != kCVReturnSuccess) return NULL;
    composer.cache = cache;
    return (TVMComposer *)CFBridgingRetain(composer);
}

void tvm_composer_free(TVMComposer *composer) {
    if (composer) CFBridgingRelease(composer);
}

/// A plane of `buffer` as a texture: 16-bit samples for 10-bit pictures, 8-bit otherwise.
static CVMetalTextureRef plane(CVMetalTextureCacheRef cache, CVPixelBufferRef buffer, size_t index, BOOL deep, BOOL write) {
    MTLPixelFormat format = index == 0 ? (deep ? MTLPixelFormatR16Unorm : MTLPixelFormatR8Unorm) : (deep ? MTLPixelFormatRG16Unorm : MTLPixelFormatRG8Unorm);
    NSDictionary *attributes = @{(__bridge NSString *)kCVMetalTextureUsage: @(write ? MTLTextureUsageShaderWrite : MTLTextureUsageShaderRead)};
    CVMetalTextureRef texture = NULL;
    if (CVMetalTextureCacheCreateTextureFromImage(NULL, cache, buffer, (__bridge CFDictionaryRef)attributes, format,
                                                  CVPixelBufferGetWidthOfPlane(buffer, index), CVPixelBufferGetHeightOfPlane(buffer, index),
                                                  index, &texture) != kCVReturnSuccess) return NULL;
    return texture;
}

static BOOL is_deep(OSType format) {
    return format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange;
}

static BOOL is_planar420(OSType format) {
    return is_deep(format) || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
}

int tvm_compose(TVMComposer *handle, const TVMReshaping *mapping, void *sourceBuffer, void *targetBuffer) {
    @autoreleasepool {
        TVMComposerObject *composer = (__bridge TVMComposerObject *)handle;
        CVPixelBufferRef source = sourceBuffer, target = targetBuffer;
        OSType input = CVPixelBufferGetPixelFormatType(source);
        if (!composer || !is_planar420(input) || CVPixelBufferGetPixelFormatType(target) != kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange) return -1;
        id<MTLDevice> device = nil;
        id<MTLComputePipelineState> state = pipeline(&device);
        BOOL deep = is_deep(input);
        CVMetalTextureRef textures[4] = {plane(composer.cache, source, 0, deep, NO), plane(composer.cache, source, 1, deep, NO),
                                         plane(composer.cache, target, 0, YES, YES), plane(composer.cache, target, 1, YES, YES)};
        int status = -1;
        id<MTLCommandBuffer> commands = textures[0] && textures[1] && textures[2] && textures[3] ? [composer.queue commandBuffer] : nil;
        id<MTLComputeCommandEncoder> encoder = [commands computeCommandEncoder];
        if (encoder) {
            [encoder setComputePipelineState:state];
            for (NSUInteger i = 0; i < 4; i++) [encoder setTexture:CVMetalTextureGetTexture(textures[i]) atIndex:i];
            // A sample's code over 2^bit depth: 10 bits in the top of 16, or 8.
            float scale = deep ? 65535.0f / 65536.0f : 255.0f / 256.0f;
            [encoder setBytes:mapping length:sizeof(TVMReshaping) atIndex:0];
            [encoder setBytes:&scale length:sizeof scale atIndex:1];
            size_t width = CVPixelBufferGetWidthOfPlane(target, 1), height = CVPixelBufferGetHeightOfPlane(target, 1);
            MTLSize group = MTLSizeMake(16, 16, 1);
            [encoder dispatchThreadgroups:MTLSizeMake((width + 15) / 16, (height + 15) / 16, 1) threadsPerThreadgroup:group];
            [encoder endEncoding];
            [commands commit];
            [commands waitUntilCompleted];
            status = commands.status == MTLCommandBufferStatusCompleted ? 0 : -1;
        }
        for (int i = 0; i < 4; i++) if (textures[i]) CFRelease(textures[i]);
        // The decoder's pictures come and go: the cache keeps none of them.
        CVMetalTextureCacheFlush(composer.cache, 0);
        return status;
    }
}
