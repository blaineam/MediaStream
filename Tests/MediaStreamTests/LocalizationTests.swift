//
//  LocalizationTests.swift
//  MediaStreamTests
//
//  MediaStream ships its own String Catalog. These guard that the compiled
//  tables exist for every Big 8 language, resolve from the package bundle,
//  and that the localized default block copy stays source-compatible.
//

import XCTest
@testable import MediaStream

final class LocalizationTests: XCTestCase {

    private let bigEight = ["zh-Hans", "ja", "de", "fr", "es", "ko", "pt-BR", "it"]

    private func bundle(for language: String) throws -> Bundle {
        // Xcode compiles the String Catalog into <lang>.lproj tables (that's how
        // host apps consume the package). Some SwiftPM command-line toolchains
        // (e.g. Swift 6.1 `swift test` on CI) copy the .xcstrings uncompiled, so
        // there are no per-language tables to inspect — skip rather than fail.
        if Bundle.module.path(forResource: language, ofType: "lproj") == nil,
           Bundle.module.path(forResource: "Localizable", ofType: "xcstrings") != nil {
            throw XCTSkip("String Catalog not compiled by this toolchain (SwiftPM CLI); covered by the Xcode test job")
        }
        let path = try XCTUnwrap(Bundle.module.path(forResource: language, ofType: "lproj"),
                                 "\(language).lproj missing from the MediaStream bundle")
        return try XCTUnwrap(Bundle(path: path))
    }

    func testEveryBigEightLanguageShipsATable() throws {
        for language in bigEight {
            let table = try bundle(for: language)
            let revealAll = table.localizedString(forKey: "Reveal All", value: "∅", table: nil)
            XCTAssertNotEqual(revealAll, "∅", "\(language): Reveal All not found")
            XCTAssertNotEqual(revealAll, "Reveal All", "\(language): Reveal All is untranslated")
        }
    }

    func testItalianStringsAndPlurals() throws {
        let italian = try bundle(for: "it")
        XCTAssertEqual(italian.localizedString(forKey: "Slideshow Duration", value: nil, table: nil), "Durata presentazione")
        XCTAssertEqual(italian.localizedString(forKey: "Verify Age", value: nil, table: nil), "Verifica età")

        let format = italian.localizedString(forKey: "This will remove %lld cached files (%@ MB)", value: nil, table: nil)
        let italianLocale = Locale(identifier: "it")
        XCTAssertEqual(String(format: format, locale: italianLocale, 1, "2,0"), "Verrà rimosso 1 file dalla cache (2,0 MB)")
        XCTAssertEqual(String(format: format, locale: italianLocale, 3, "2,0"), "Verranno rimossi 3 file dalla cache (2,0 MB)")
    }

    func testBlockCopyDefaultsAndOverrides() {
        // Defaults resolve from the package bundle in whatever language the
        // test host runs in.
        let generic = SensitiveBlockCopy()
        XCTAssertEqual(generic.title, Bundle.module.localizedString(forKey: "Sensitive Content", value: nil, table: nil))
        XCTAssertFalse(generic.revealMessage.isEmpty)
        XCTAssertFalse(generic.verifyMessage.isEmpty)
        XCTAssertFalse(generic.lockedMessage.isEmpty)

        // Hosts that pass their own copy (Ari) still get it verbatim.
        let custom = SensitiveBlockCopy(title: "Hidden", lockedMessage: "Locked")
        XCTAssertEqual(custom.title, "Hidden")
        XCTAssertEqual(custom.lockedMessage, "Locked")
        XCTAssertEqual(custom.revealMessage, generic.revealMessage)
    }

    func testFilterNamesAreLocalizedButRawValuesStayStable() {
        XCTAssertEqual(MediaFilter.images.rawValue, "Images")
        XCTAssertEqual(MediaFilter.images.localizedName,
                       Bundle.module.localizedString(forKey: "Images", value: nil, table: nil))
    }
}
