import Foundation

struct ColorToolsUniform {
    var band0, band1, band2, band3, band4, band5, band6, band7: SIMD4<Float>
    init(_ color: ColorAdjustments) {
        band0 = SIMD4(color.mixer[0], 0)
        band1 = SIMD4(color.mixer[1], 0)
        band2 = SIMD4(color.mixer[2], 0)
        band3 = SIMD4(color.mixer[3], 0)
        band4 = SIMD4(color.mixer[4], 0)
        band5 = SIMD4(color.mixer[5], 0)
        band6 = SIMD4(color.mixer[6], 0)
        band7 = SIMD4(color.mixer[7], 0)
    }
}
