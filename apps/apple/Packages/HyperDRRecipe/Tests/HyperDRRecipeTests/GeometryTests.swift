import Foundation
import Testing
@testable import HyperDRRecipe

/// The crop pane's geometry: one transform and one output size for the
/// editor, the engine and the export.
@Suite struct GeometryTests {
    let photo = GeometrySize(width: 4000, height: 3000)

    func close(_ a: GeometryPoint, _ b: GeometryPoint, _ tolerance: Double = 1e-6) -> Bool {
        abs(a.x - b.x) < tolerance && abs(a.y - b.y) < tolerance
    }

    @Test func theIdentityKeepsThePhoto() {
        let geometry = Geometry.identity
        #expect(geometry.outputSize(of: photo) == (4000, 3000))
        #expect(geometry.resolvedCrop(for: photo) == CropRect(centreX: 0, centreY: 0, width: 1, height: 1))
        #expect(geometry.quad(for: photo)[0] == GeometryPoint(x: -2000, y: -1500))
        #expect(!geometry.transformsPixels)
    }

    @Test func aQuarterTurnSwapsTheFrameWithoutResampling() {
        let turned = Geometry.identity.turnedLeft()
        #expect(turned.outputSize(of: photo) == (3000, 4000))
        // Anticlockwise: the photo's right edge comes to the top.
        #expect(turned.transform(for: photo).apply(GeometryPoint(x: 2000, y: 0)) == GeometryPoint(x: 0, y: -2000))
        #expect(!turned.transformsPixels)
        var round = Geometry(crop: CropRect(centreX: 0.1, centreY: -0.2, width: 0.5, height: 0.4))
        let start = round
        for _ in 0..<4 { round = round.turnedLeft() }
        #expect(round == start)
    }

    @Test func straighteningCropsToTheLargestRectangleInside() throws {
        let geometry = Geometry(angle: 10)
        let quad = geometry.quad(for: photo)
        let rect = geometry.cropRect(for: photo)
        #expect(rect.corners.allSatisfy { Geometry.contains(quad, $0) })
        let larger = GeometryRect(centre: rect.centre, size: GeometrySize(width: rect.width * 1.002, height: rect.height * 1.002))
        #expect(!larger.corners.allSatisfy { Geometry.contains(quad, $0) }, "and no larger")
        #expect(abs(rect.width / rect.height - 4.0 / 3.0) < 1e-6, "the original ratio")
        let size = geometry.outputSize(of: photo)
        #expect(size.width < 4000 && size.height < 3000)
        // Resolution independent: half the pixels, half the output.
        let half = geometry.outputSize(of: GeometrySize(width: 2000, height: 1500))
        #expect(abs(Double(half.width) - Double(size.width) / 2) <= 1)
    }

    @Test func aCropThatNoLongerFitsShrinksAboutItsCentre() {
        var geometry = Geometry(crop: CropRect(centreX: 0.1, centreY: 0, width: 0.6, height: 0.6))
        #expect(geometry.resolvedCrop(for: photo) == geometry.crop, "fits: kept as it is")
        geometry.angle = 30
        let resolved = geometry.resolvedCrop(for: photo)
        #expect(resolved.width < 0.6 && abs(resolved.centreX - 0.1) < 1e-9)
        #expect(abs(resolved.width / resolved.height - 1) < 1e-6, "its ratio kept")
    }

    @Test func perspectiveWidensTheSideItBringsCloser() {
        let up = Geometry(vertical: 50).quad(for: photo)
        #expect(up[1].x - up[0].x > up[2].x - up[3].x, "positive vertical: the top is wider")
        let right = Geometry(horizontal: 50).quad(for: photo)
        #expect(right[2].y - right[1].y > right[3].y - right[0].y, "positive horizontal: the right is taller")
        #expect(close(Geometry(vertical: 50).transform(for: photo).apply(GeometryPoint(x: 0, y: 0)), GeometryPoint(x: 0, y: 0)),
                "the centre stays")
        #expect(Geometry(vertical: 50).transformsPixels)
    }

    @Test func mirroringMirrorsTheViewAsItIs() {
        let geometry = Geometry(angle: 12, vertical: 20, horizontal: -30, quarterTurns: 1,
                                crop: CropRect(centreX: 0.1, centreY: 0.05, width: 0.4, height: 0.3))
        let mirrored = geometry.mirrored()
        for point in [GeometryPoint(x: 300, y: -700), GeometryPoint(x: -1500, y: 900)] {
            let seen = geometry.transform(for: photo).apply(point)
            // The mirrored view of the same photo point is the old view mirrored.
            let flippedView = mirrored.transform(for: photo).apply(point)
            #expect(close(flippedView, GeometryPoint(x: -seen.x, y: seen.y), 1e-6))
        }
        #expect(mirrored.crop?.centreX == -0.1)
        #expect(mirrored.mirrored() == geometry)
    }

    @Test func turningLeftTurnsTheViewAsItIs() {
        let geometry = Geometry(angle: -7, horizontal: 15, flipped: true)
        let turned = geometry.turnedLeft()
        let point = GeometryPoint(x: 800, y: 400)
        let seen = geometry.transform(for: photo).apply(point)
        #expect(close(turned.transform(for: photo).apply(point), GeometryPoint(x: seen.y, y: -seen.x), 1e-6))
    }

    @Test func aspectsTurnAndKnowTheirRatios() {
        let frame = GeometrySize(width: 3000, height: 4000)
        #expect(CropAspect.original.ratio(frame: frame) == 0.75)
        #expect(CropAspect.free.ratio(frame: frame) == nil)
        #expect(CropAspect.portrait4x5.ratio(frame: frame) == 0.8)
        #expect(CropAspect.portrait4x5.turned == .landscape5x4 && CropAspect.landscape5x4.turned == .portrait4x5)
        #expect(CropAspect.allCases.allSatisfy { $0.turned.turned == $0 })
        let square = Geometry(aspect: .square).outputSize(of: photo)
        #expect(square == (3000, 3000))
    }

    @Test func aNewAspectKeepsTheCropsCentre() {
        let geometry = Geometry(aspect: .free, crop: CropRect(centreX: 0.2, centreY: 0, width: 0.4, height: 0.6))
        let square = geometry.settingAspect(.square, photo: photo)
        let rect = square.cropRect(for: photo)
        #expect(abs(rect.width - rect.height) < 1e-6 && abs(rect.centre.x - 0.2 * 4000) < 1e-6)
        #expect(rect.corners.allSatisfy { Geometry.contains(square.quad(for: photo), $0) })
        #expect(geometry.settingAspect(.free, photo: photo).crop == geometry.crop)
        #expect(Geometry.identity.settingAspect(.original, photo: photo).crop == nil, "the photo's own ratio stays automatic")
    }

    @Test func geometryWritesOnlyWhatIsNotTheIdentity() throws {
        let plain = Recipe(inputDomain: .sdr)
        #expect(!(try plain.jsonString()).contains("geometry"), "a recipe without one keeps its bytes")
        var recipe = plain
        recipe.geometry = Geometry(angle: 2.5, aspect: .portrait4x5)
        let json = try recipe.jsonString()
        #expect(json.contains(#""geometry":{"angle":2.5,"aspect":"4:5"}"#))
        #expect(try Recipe.decode(Data(json.utf8)) == recipe)
        // A ratio from a newer build reads as free; missing fields as their defaults.
        let newer = #"{"geometry":{"aspect":"7:5","quarterTurns":5},"inputDomain":"sdr","version":1}"#
        let decoded = try Recipe.decode(Data(newer.utf8))
        #expect(decoded.geometry.aspect == .free && decoded.geometry.quarterTurns == 1)
    }
}
