import Foundation
import XCTest
import PlanMeterWatchShared

final class ComplicationPreferencesTests: XCTestCase {
    func testPreferencesPersistAndTravelWithUsageWithoutChangingFreshness() throws {
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var preferences = ComplicationPreferences()
        preferences.personal = false
        preferences.other = false
        preferences.dailyTarget = 125.50
        preferences.save(to: defaults)
        XCTAssertEqual(ComplicationPreferences.load(from: defaults), preferences)
        let date = Date(timeIntervalSince1970: 1000)
        let payload = WatchPayload(updatedAt: date, days: 30, serverName: "Mac", personalCostUsd: 0, workCostUsd: 10, otherCostUsd: 0, personalTokens: 0, workTokens: 0, todayCostUsd: 10, accounts: [], limits: [], complicationPreferences: preferences)
        let decoded = try XCTUnwrap(WatchPayload.decode(try XCTUnwrap(payload.encoded())))
        XCTAssertEqual(decoded.complicationPreferences, preferences)
        XCTAssertEqual(decoded.updatedAt, date)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(payload.encoded())) as? [String: Any])
        legacy.removeValue(forKey: "complicationPreferences")
        XCTAssertNil(try XCTUnwrap(WatchPayload.decode(JSONSerialization.data(withJSONObject: legacy))).complicationPreferences)
    }

    func testLocalizedTargetValidation() {
        let en = Locale(identifier: "en_US")
        let de = Locale(identifier: "de_DE")
        XCTAssertEqual(ComplicationPreferences.parseTarget("125.50", locale: en), 125.50)
        XCTAssertEqual(ComplicationPreferences.parseTarget("125,50", locale: de), 125.50)
        for text in ["", "0", "-1", "nan", "inf", "12abc", "1.2.3", "1000000001"] {
            XCTAssertNil(ComplicationPreferences.parseTarget(text, locale: en), text)
        }
        XCTAssertNil(ComplicationPreferences().target)
    }
}
