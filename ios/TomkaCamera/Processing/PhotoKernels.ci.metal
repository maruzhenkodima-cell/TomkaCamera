#include <CoreImage/CoreImage.h>

using namespace metal;

inline float luminance(float3 rgb) {
    return dot(rgb, float3(0.2126, 0.7152, 0.0722));
}

// Two-frame fusion: average only when the samples agree. When content differs,
// keep the reference sample rather than creating a double edge or ghost.
extern "C" float4 adaptiveMerge2(
    coreimage::sample_t referenceSample,
    coreimage::sample_t secondSample
) {
    float4 reference = referenceSample;
    float4 second = secondSample;

    float difference = abs(
        luminance(reference.rgb) - luminance(second.rgb)
    );

    if (difference <= 0.022) {
        return float4((reference.rgb + second.rgb) * 0.5, 1.0);
    }

    return float4(reference.rgb, 1.0);
}

// Three-frame fusion: average all three in stable regions for the best noise
// reduction. In changed regions, choose the whole RGB sample with median
// luminance. This rejects a single moving/outlier sample without independently
// sorting RGB channels (which can create colors that never existed in a frame).
extern "C" float4 adaptiveMerge3(
    coreimage::sample_t firstSample,
    coreimage::sample_t secondSample,
    coreimage::sample_t thirdSample
) {
    float4 a = firstSample;
    float4 b = secondSample;
    float4 c = thirdSample;

    float la = luminance(a.rgb);
    float lb = luminance(b.rgb);
    float lc = luminance(c.rgb);

    float minimumLuma = min(la, min(lb, lc));
    float maximumLuma = max(la, max(lb, lc));

    if (maximumLuma - minimumLuma <= 0.022) {
        return float4((a.rgb + b.rgb + c.rgb) / 3.0, 1.0);
    }

    float3 medianPixel;
    if ((la <= lb && lb <= lc) || (lc <= lb && lb <= la)) {
        medianPixel = b.rgb;
    } else if ((lb <= la && la <= lc) || (lc <= la && la <= lb)) {
        medianPixel = a.rgb;
    } else {
        medianPixel = c.rgb;
    }

    return float4(medianPixel, 1.0);
}
