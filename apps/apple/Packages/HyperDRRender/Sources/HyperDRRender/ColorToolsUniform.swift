import Foundation

struct ColorToolsUniform {
    var band0, band1, band2, band3, band4, band5, band6, band7: SIMD4<Float>
    var grade0, grade1, grade2, grade3, gradeOptions: SIMD4<Float>
    init(_ color: ColorAdjustments) {
        band0 = SIMD4(color.mixer[0], 0)
        band1 = SIMD4(color.mixer[1], 0)
        band2 = SIMD4(color.mixer[2], 0)
        band3 = SIMD4(color.mixer[3], 0)
        band4 = SIMD4(color.mixer[4], 0)
        band5 = SIMD4(color.mixer[5], 0)
        band6 = SIMD4(color.mixer[6], 0)
        band7 = SIMD4(color.mixer[7], 0)
        grade0 = SIMD4(color.grading[0],0)
        grade1 = SIMD4(color.grading[1],0)
        grade2 = SIMD4(color.grading[2],0)
        grade3 = SIMD4(color.grading[3],0)
        // Shader hue is the OKLCH angle; recipe/UI hue is the sRGB wheel.
        grade0.x = Float(DoubleReference.gradingHue(Double(color.grading[0].x))*180/Double.pi)
        grade1.x = Float(DoubleReference.gradingHue(Double(color.grading[1].x))*180/Double.pi)
        grade2.x = Float(DoubleReference.gradingHue(Double(color.grading[2].x))*180/Double.pi)
        grade3.x = Float(DoubleReference.gradingHue(Double(color.grading[3].x))*180/Double.pi)
        gradeOptions = SIMD4(color.gradingBlending,color.gradingBalance,0,0)
    }
}
