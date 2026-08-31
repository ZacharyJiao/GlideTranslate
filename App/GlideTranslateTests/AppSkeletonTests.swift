import XCTest

final class AppSkeletonTests: XCTestCase {
    func testApprovedIdentityAndMinimumSystemVersion() throws {
        let bundle = try XCTUnwrap(
            Bundle(identifier: "com.zaryolabs.GlideTranslate")
        )
        let rawInfo = try XCTUnwrap(
            NSDictionary(contentsOf: bundle.bundleURL.appendingPathComponent("Contents/Info.plist"))
        )
        XCTAssertEqual(
            rawInfo["CFBundleDisplayName"] as? String,
            "Glide Translate"
        )
        XCTAssertEqual(
            rawInfo["LSMinimumSystemVersion"] as? String,
            "14.0"
        )
        XCTAssertEqual(
            rawInfo["CFBundleShortVersionString"] as? String,
            "0.2.1"
        )
        XCTAssertEqual(
            rawInfo["CFBundleVersion"] as? String,
            "2"
        )
        let resources = try XCTUnwrap(bundle.resourceURL)
        let chineseInfo = try XCTUnwrap(
            NSDictionary(
                contentsOf: resources
                    .appendingPathComponent("zh-Hans.lproj")
                    .appendingPathComponent("InfoPlist.strings")
            )
        )
        XCTAssertEqual(chineseInfo["CFBundleDisplayName"] as? String, "轻译")
    }
}
