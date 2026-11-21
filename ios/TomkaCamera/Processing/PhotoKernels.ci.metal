#include <CoreImage/CoreImage.h>

using namespace metal;

// Per-channel median of three registered frames. A single moving object or
// bad sample is rejected without blending it into a ghost.
extern "C" float4 median3(
    coreimage::sample_t first,
    coreimage::sample_t second,
    coreimage::sample_t third
) {
    float4 a = first;
    float4 b = second;
    float4 c = third;

    float4 lowValue = min(a, b);
    float4 highValue = max(a, b);
    float4 middleValue = max(lowValue, min(highValue, c));

    return float4(middleValue.rgb, 1.0);
}
