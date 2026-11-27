import XCTest
@testable import QuackDeck

final class LegalNoticesTests: XCTestCase {
    func testAllLegalDocumentsLoadFromAppBundle() throws {
        let appBundle = Bundle(for: AppState.self)

        for doc in LegalDocument.allCases {
            let text = try XCTUnwrap(
                doc.loadText(in: appBundle),
                "Missing bundled legal document: \(doc.resourceName)"
            )
            XCTAssertFalse(
                text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "Legal document \(doc.resourceName) must not be empty"
            )
        }

        let apacheText = try XCTUnwrap(LegalDocument.apacheLicense.loadText(in: appBundle))
        XCTAssertTrue(apacheText.contains("Apache License"))
        XCTAssertTrue(apacheText.contains("Version 2.0, January 2004"))

        let noticeText = try XCTUnwrap(LegalDocument.notice.loadText(in: appBundle))
        let normalizedNotice = noticeText.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        XCTAssertTrue(normalizedNotice.contains("Copyright 2026 Rafael Caricio"))
        XCTAssertTrue(normalizedNotice.contains("Pollen Robotics"))
        XCTAssertTrue(normalizedNotice.contains("Apache License, Version 2.0"))
        XCTAssertTrue(normalizedNotice.contains("not affiliated with, endorsed by, or sponsored by Pollen Robotics"))

        let webrtcText = try XCTUnwrap(LegalDocument.webrtcLicense.loadText(in: appBundle))
        XCTAssertTrue(webrtcText.contains("BSD 3-Clause License"))
        XCTAssertTrue(webrtcText.contains("Google WebRTC"))

        let thirdPartyText = try XCTUnwrap(LegalDocument.thirdPartyNotices.loadText(in: appBundle))
        XCTAssertTrue(thirdPartyText.contains("duck-auth"))
        XCTAssertTrue(thirdPartyText.contains("duck-ble"))
        XCTAssertTrue(thirdPartyText.contains("duck-ipc-proto"))
        XCTAssertTrue(thirdPartyText.contains("curve25519-dalek"))
    }
}
