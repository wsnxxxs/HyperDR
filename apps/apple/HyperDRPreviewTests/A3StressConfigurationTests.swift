#if DEBUG
import Foundation
import XCTest
@testable import HyperDR

@MainActor final class A3StressConfigurationTests: XCTestCase {
    func testOnlyArgumentDomainEnablesStressAndEdge() throws {
        let suite = "a3-stress-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        let registration = defaults.volatileDomain(forName: UserDefaults.registrationDomain)
        defer {
            defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            defaults.setVolatileDomain(registration, forName: UserDefaults.registrationDomain)
            defaults.removePersistentDomain(forName: suite)
        }
        defaults.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
        defaults.register(defaults: ["HDRA3Stress": "steps", "HDRA3Edge": 640])
        XCTAssertNil(A3StressRunner.configuration(defaults: defaults))
        defaults.set("drag", forKey: "HDRA3Stress")
        defaults.set(2048, forKey: "HDRA3Edge")
        XCTAssertNil(A3StressRunner.configuration(defaults: defaults))
        defaults.setVolatileDomain(["HDRA3Stress": "unknown", "HDRA3Edge": "640"], forName: UserDefaults.argumentDomain)
        XCTAssertNil(A3StressRunner.configuration(defaults: defaults))
        defaults.setVolatileDomain(["HDRA3Stress": "steps", "HDRA3Edge": "640"], forName: UserDefaults.argumentDomain)
        XCTAssertEqual(A3StressRunner.configuration(defaults: defaults)?.mode, .steps)
        XCTAssertEqual(A3StressRunner.configuration(defaults: defaults)?.edge, 640)
        defaults.setVolatileDomain(["HDRA3Stress": "drag", "HDRA3Edge": "2048"], forName: UserDefaults.argumentDomain)
        XCTAssertEqual(A3StressRunner.configuration(defaults: defaults)?.mode, .drag)
        XCTAssertEqual(A3StressRunner.configuration(defaults: defaults)?.edge, 2048)
        defaults.setVolatileDomain(["HDRA3Stress": "drag", "HDRA3Edge": "123"], forName: UserDefaults.argumentDomain)
        XCTAssertNil(A3StressRunner.configuration(defaults: defaults)?.edge)
    }

    func testRegistrationAloneCannotEnableStandardRunner() {
        let defaults = UserDefaults.standard
        let saved = defaults.volatileDomain(forName: UserDefaults.registrationDomain)
        defer { defaults.setVolatileDomain(saved, forName: UserDefaults.registrationDomain) }
        XCTAssertNil(A3StressRunner.configuration())
        defaults.register(defaults: ["HDRA3Stress": "steps", "HDRA3Edge": 640])
        XCTAssertNil(A3StressRunner.configuration())
        XCTAssertNil(A3StressRunner.edge)
    }
}
#endif
