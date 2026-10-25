import Foundation

/// SDR coordinates are sRGB lightness; HDR coordinates are 1 + stops above white.
/// Black and SDR white remain fixed. HDR interpolation is independent of SDR.
public struct ToneCurve: Hashable, Sendable {
    public enum Error: Swift.Error { case invalidPoints }
    public let coordinates: [Double]
    public init() { coordinates = [0, 0, 1, 1] }
    public init(_ coordinates: [Double]) throws {
        guard coordinates.count >= 4, coordinates.count <= 32, coordinates.count.isMultiple(of: 2),
              Array(coordinates.prefix(2)) == [0, 0], stride(from: 0, to: coordinates.count, by: 2).contains(where: { coordinates[$0] == 1 && coordinates[$0+1] == 1 }),
              coordinates.allSatisfy({ $0.isFinite && (0...5).contains($0) }) else { throw Error.invalidPoints }
        for index in stride(from: 2, to: coordinates.count, by: 2) {
            guard coordinates[index] > coordinates[index-2],
                  (coordinates[index] <= 1 ? coordinates[index+1] <= 1 : coordinates[index+1] >= 1) else { throw Error.invalidPoints }
        }
        self.coordinates = coordinates
    }
    public var isIdentity: Bool {
        stride(from: 0, to: coordinates.count, by: 2).allSatisfy { coordinates[$0] == coordinates[$0+1] }
    }
    /// Samples in the same perceptual coordinates the controls edit. Shared by
    /// the curve editor and the renderer's 1D table.
    public func samples(count: Int = 1024, from lower: Double = 0, through upper: Double = 1) -> [Double] {
        return (0..<count).map { value(at: lower+(upper-lower)*Double($0)/Double(count-1)) }
    }
    public func value(at input: Double) -> Double {
        let white = stride(from: 0, to: coordinates.count, by: 2).first { coordinates[$0] == 1 }!
        if input <= 1 { return ToneCurveInterpolation(Array(coordinates[...(white+1)])).value(at: input) }
        guard white+2 < coordinates.count else { return input }
        return ToneCurveInterpolation(Array(coordinates[white...])).value(at: input)
    }
    public var parameterValue: ParameterValue { .array(coordinates.map(ParameterValue.number)) }
}

/// Fritsch–Carlson tangents preserve the direction of each interval, without
/// overshooting the control points. Evaluated in double precision before baking.
private struct ToneCurveInterpolation {
    let x, y, tangent: [Double]
    init(_ p: [Double]) {
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
        if input <= x[0] { return y[0] }
        if input >= x.last! { return y.last! + max(0,input-x.last!) }
        let i = (0..<(x.count-1)).first { input <= x[$0+1] }!
        let h = x[i+1]-x[i], t = (input-x[i])/h, t2 = t*t, t3 = t2*t
        return (2*t3-3*t2+1)*y[i] + (t3-2*t2+t)*h*tangent[i]
            + (-2*t3+3*t2)*y[i+1] + (t3-t2)*h*tangent[i+1]
    }
}
