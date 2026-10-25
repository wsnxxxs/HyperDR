import Foundation

/// SDR display lightness coordinates: sRGB-encoded luminance in both axes.
/// Endpoints stay fixed; Whites and Black Point move the endpoints instead.
public struct ToneCurve: Hashable, Sendable {
    public enum Error: Swift.Error { case invalidPoints }
    public let coordinates: [Double]
    public init() { coordinates = [0, 0, 1, 1] }
    public init(_ coordinates: [Double]) throws {
        guard coordinates.count >= 4, coordinates.count <= 32, coordinates.count.isMultiple(of: 2),
              Array(coordinates.prefix(2)) == [0, 0], Array(coordinates.suffix(2)) == [1, 1],
              coordinates.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw Error.invalidPoints }
        for index in stride(from: 2, to: coordinates.count, by: 2) {
            guard coordinates[index] > coordinates[index-2] else { throw Error.invalidPoints }
        }
        self.coordinates = coordinates
    }
    public var isIdentity: Bool {
        stride(from: 0, to: coordinates.count, by: 2).allSatisfy { coordinates[$0] == coordinates[$0+1] }
    }
    /// Samples in the same perceptual coordinates the controls edit. Shared by
    /// the curve editor and the renderer's 1D table.
    public func samples(count: Int = 1024) -> [Double] {
        let interpolation = ToneCurveInterpolation(self)
        return (0..<count).map { interpolation.value(at: Double($0)/Double(count-1)) }
    }
    public func value(at input: Double) -> Double { ToneCurveInterpolation(self).value(at: input) }
    public var parameterValue: ParameterValue { .array(coordinates.map(ParameterValue.number)) }
}

/// Fritsch–Carlson tangents preserve the direction of each interval, without
/// overshooting the control points. Evaluated in double precision before baking.
private struct ToneCurveInterpolation {
    let x, y, tangent: [Double]
    init(_ curve: ToneCurve) {
        let p = curve.coordinates
        let x = stride(from: 0, to: p.count, by: 2).map { p[$0] }
        let y = stride(from: 1, to: p.count, by: 2).map { p[$0] }
        let slopes = (0..<(x.count-1)).map { (y[$0+1]-y[$0])/(x[$0+1]-x[$0]) }
        var m = [slopes[0]] + (1..<(x.count-1)).map { i in
            slopes[i-1]*slopes[i] <= 0 ? 0 : (slopes[i-1]+slopes[i])/2
        } + [slopes.last!]
        for i in slopes.indices {
            if slopes[i] == 0 { m[i] = 0; m[i+1] = 0; continue }
            let a = m[i]/slopes[i], b = m[i+1]/slopes[i]
            let norm = a*a+b*b
            if norm > 9 {
                let factor = 3/sqrt(norm)
                m[i] = factor*a*slopes[i]; m[i+1] = factor*b*slopes[i]
            }
        }
        self.x = x; self.y = y; tangent = m
    }
    func value(at input: Double) -> Double {
        if input <= 0 { return 0 }
        if input >= 1 { return 1 }
        let i = (0..<(x.count-1)).first { input <= x[$0+1] }!
        let h = x[i+1]-x[i], t = (input-x[i])/h, t2 = t*t, t3 = t2*t
        return (2*t3-3*t2+1)*y[i] + (t3-2*t2+t)*h*tangent[i]
            + (-2*t3+3*t2)*y[i+1] + (t3-t2)*h*tangent[i+1]
    }
}
