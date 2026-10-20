import Foundation
import Testing
@testable import HyperDREngine



@Test func frameLayoutIsPureAndStrict() throws {
    let layout = try Engine.frameLayout(frame: ["margins": .number(0.05), "caption": .number(0.1)],
                                        photoWidth: 3000, photoHeight: 2000)
    #expect(layout.width == 3200 && layout.height == 2400)
    #expect(layout.photo == FrameLayout.Rect(x: 100, y: 100, width: 3000, height: 2000))
    #expect(layout.caption == FrameLayout.Rect(x: 0, y: 2100, width: 3200, height: 300))
    #expect(throws: HyperDRError.self) {
        try Engine.frameLayout(frame: ["margin": .number(0.05)], photoWidth: 3000, photoHeight: 2000)
    }
    #expect(throws: HyperDRError.self) {
        try Engine.frameLayout(frame: [:], photoWidth: 0, photoHeight: 2000)
    }
}



@Test func packagingABIVersion() { #expect(Engine.abiVersion == 5) }
