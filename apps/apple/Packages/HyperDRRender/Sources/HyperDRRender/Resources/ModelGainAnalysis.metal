#include <metal_stdlib>
using namespace metal;

// Equal-area analysis scaling, the GPU half of `ModelGainResampler`.
//
// One thread per destination pixel. Every contribution is a source pixel weighted
// by the fraction of that destination pixel's footprint it covers, so the result
// is the engine's staged area reduction (`modules/image/src/resample.cpp`) rather
// than a point sample: fine alternating detail averages out instead of aliasing.
//
// The per-row and per-column footprints are prepared on the CPU because they
// depend on the reduction ratio and on each output pixel's phase, and are passed
// as flat tap tables. `origin` shifts the table's global source coordinates onto
// a tile, which is how a source too large to materialize whole is rendered a band
// at a time.

kernel void modelGainAnalysisAverage(
    texture2d<float, access::read> source [[texture(0)]],
    texture2d<float, access::write> destination [[texture(1)]],
    const device int* firstX [[buffer(0)]],
    const device int* countX [[buffer(1)]],
    const device float* weightsX [[buffer(2)]],
    const device int* firstY [[buffer(3)]],
    const device int* countY [[buffer(4)]],
    const device float* weightsY [[buffer(5)]],
    constant int& strideX [[buffer(6)]],
    constant int& strideY [[buffer(7)]],
    constant int2& sourceOrigin [[buffer(8)]],
    constant int& destinationOriginY [[buffer(9)]],
    uint2 tile [[thread_position_in_grid]])
{
    const int x = static_cast<int>(tile.x);
    // The tap tables cover the whole destination image, so the row they are
    // indexed with is the global one; a band only shifts where the result is
    // written and which source rows the tile holds.
    const int y = static_cast<int>(tile.y) + destinationOriginY;
    if (x >= static_cast<int>(destination.get_width()) ||
        y >= static_cast<int>(destination.get_height())) return;

    const int tapsX = countX[x];
    const int tapsY = countY[y];
    const int startX = firstX[x] + sourceOrigin.x;
    const int startY = firstY[y] + sourceOrigin.y;
    const device float* rowWeights = weightsX + x * strideX;
    const device float* columnWeights = weightsY + y * strideY;

    float4 sum = 0.0f;
    for (int j = 0; j < tapsY; ++j) {
        const float weightY = columnWeights[j];
        if (weightY == 0.0f) continue;
        const int sourceY = startY + j;
        for (int i = 0; i < tapsX; ++i) {
            const float weight = rowWeights[i] * weightY;
            if (weight == 0.0f) continue;
            sum += source.read(uint2(startX + i, sourceY)) * weight;
        }
    }
    destination.write(sum, uint2(x, y));
}
