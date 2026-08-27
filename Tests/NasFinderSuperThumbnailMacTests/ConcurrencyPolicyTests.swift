import Foundation
import XCTest
@testable import NasFinderSuperThumbnailMac

final class ConcurrencyPolicyTests: XCTestCase {
    private typealias Policy = SuperThumbnailConcurrencyPolicy
    private typealias Settings = SuperThumbnailConcurrencySettings
    private typealias Persistence = SuperThumbnailConcurrencyPersistence

    // MARK: - Settings / defaults

    func testSupportedRangeAndClamping() {
        XCTAssertEqual(Policy.supportedWorkerRange, 1...16)
        XCTAssertEqual(Policy.clampRequestedWorkerCount(0), 1)
        XCTAssertEqual(Policy.clampRequestedWorkerCount(-5), 1)
        XCTAssertEqual(Policy.clampRequestedWorkerCount(1), 1)
        XCTAssertEqual(Policy.clampRequestedWorkerCount(9), 9)
        XCTAssertEqual(Policy.clampRequestedWorkerCount(16), 16)
        XCTAssertEqual(Policy.clampRequestedWorkerCount(64), 16)

        // The settings initializer clamps too, so stored garbage can never produce 0 workers.
        XCTAssertEqual(Settings(isAutoEnabled: true, requestedWorkerCount: 0).requestedWorkerCount, 1)
        XCTAssertEqual(Settings(isAutoEnabled: false, requestedWorkerCount: 100).requestedWorkerCount, 16)
    }

    func testDefaultRequestedWorkerCountIsProcessorDerivedAndInRange() {
        XCTAssertEqual(Policy.defaultRequestedWorkerCount(activeProcessorCount: 1), 1)
        XCTAssertEqual(Policy.defaultRequestedWorkerCount(activeProcessorCount: 8), 8)
        XCTAssertEqual(Policy.defaultRequestedWorkerCount(activeProcessorCount: 12), 12)
        XCTAssertEqual(Policy.defaultRequestedWorkerCount(activeProcessorCount: 32), 16)
        XCTAssertEqual(Policy.defaultRequestedWorkerCount(activeProcessorCount: 0), 1)

        let defaults = Settings.defaultSettings(activeProcessorCount: 10)
        XCTAssertTrue(defaults.isAutoEnabled)
        XCTAssertEqual(defaults.requestedWorkerCount, 10)

        let live = Settings.defaultSettings()
        XCTAssertTrue(Policy.supportedWorkerRange.contains(live.requestedWorkerCount))
    }

    // MARK: - Thermal detection

    func testThermalThrottlingStateDetection() {
        XCTAssertFalse(Policy.isThermalThrottled(thermalState: .nominal))
        XCTAssertFalse(Policy.isThermalThrottled(thermalState: .fair))
        XCTAssertTrue(Policy.isThermalThrottled(thermalState: .serious))
        XCTAssertTrue(Policy.isThermalThrottled(thermalState: .critical))
    }

    // MARK: - File (item-level) limits

    func testAutoOnUsesRequestedNumberWithoutPressure() {
        for requested in Policy.supportedWorkerRange {
            let settings = Settings(isAutoEnabled: true, requestedWorkerCount: requested)
            for state in [ProcessInfo.ThermalState.nominal, .fair] {
                XCTAssertEqual(
                    Policy.effectiveWorkerLimit(settings: settings, thermalState: state),
                    requested,
                    "자동이 켜져 있어도 여유가 있을 때는 요청한 \(requested)개를 그대로 써야 합니다."
                )
                XCTAssertFalse(Policy.isReducedByThermalPressure(settings: settings, thermalState: state))
            }
        }
    }

    func testAutoOnHalvesUnderSeriousAndClampsToOneUnderCritical() {
        let expectedSerious: [Int: Int] = [1: 1, 2: 1, 3: 1, 4: 2, 5: 2, 8: 4, 9: 4, 16: 8]
        for (requested, expected) in expectedSerious {
            let settings = Settings(isAutoEnabled: true, requestedWorkerCount: requested)
            XCTAssertEqual(
                Policy.effectiveWorkerLimit(settings: settings, thermalState: .serious),
                expected,
                "자동 + serious: 요청 \(requested)개는 절반(최소 1)인 \(expected)개여야 합니다."
            )
            XCTAssertEqual(
                Policy.effectiveWorkerLimit(settings: settings, thermalState: .critical),
                Policy.criticalThermalWorkerLimit
            )
            XCTAssertEqual(
                Policy.isReducedByThermalPressure(settings: settings, thermalState: .serious),
                expected < requested
            )
        }
    }

    func testAutoOffHonorsRequestedThroughSeriousButNeverIgnoresCritical() {
        for requested in [1, 2, 4, 8, 16] {
            let settings = Settings(isAutoEnabled: false, requestedWorkerCount: requested)
            for state in [ProcessInfo.ThermalState.nominal, .fair, .serious] {
                XCTAssertEqual(
                    Policy.effectiveWorkerLimit(settings: settings, thermalState: state),
                    requested,
                    "자동이 꺼져 있으면 serious까지는 사용자가 정한 \(requested)개를 그대로 써야 합니다."
                )
                XCTAssertFalse(Policy.isReducedByThermalPressure(settings: settings, thermalState: state))
            }
            XCTAssertEqual(
                Policy.effectiveWorkerLimit(settings: settings, thermalState: .critical),
                1,
                "critical 발열은 자동 여부와 관계없이 1개로 제한해야 합니다."
            )
            XCTAssertEqual(
                Policy.isReducedByThermalPressure(settings: settings, thermalState: .critical),
                requested > 1
            )
        }
    }

    func testEffectiveWorkerLimitIsAlwaysAtLeastOne() {
        for isAuto in [true, false] {
            for state in [ProcessInfo.ThermalState.nominal, .fair, .serious, .critical] {
                let settings = Settings(isAutoEnabled: isAuto, requestedWorkerCount: 1)
                XCTAssertEqual(Policy.effectiveWorkerLimit(settings: settings, thermalState: state), 1)
                XCTAssertEqual(Policy.effectiveFolderWorkerLimit(settings: settings, thermalState: state), 1)
            }
        }
    }

    // MARK: - Folder limits

    func testFolderLimitIsHalfOfFileLimitWithRemainderDroppedAndMinimumOne() {
        XCTAssertEqual(Policy.minimumFolderWorkerLimit, 1)
        let expected: [Int: Int] = [
            1: 1, 2: 1, 3: 1, 4: 2, 5: 2, 6: 3, 7: 3, 8: 4, 9: 4, 10: 5, 15: 7, 16: 8,
        ]
        for (fileLimit, folderLimit) in expected {
            XCTAssertEqual(
                Policy.folderWorkerLimit(fileWorkerLimit: fileLimit),
                folderLimit,
                "파일 \(fileLimit)개 → 폴더 \(folderLimit)개 (절반, 나머지 버림, 최소 1)"
            )
        }
        // A worker pool cannot run with 0: requested 1 must map to the documented minimum of 1.
        XCTAssertEqual(Policy.folderWorkerLimit(fileWorkerLimit: 1), Policy.minimumFolderWorkerLimit)
        XCTAssertEqual(Policy.folderWorkerLimit(fileWorkerLimit: 0), Policy.minimumFolderWorkerLimit)
    }

    func testEffectiveFolderLimitFollowsThermalReductionOfFileLimit() {
        let auto8 = Settings(isAutoEnabled: true, requestedWorkerCount: 8)
        XCTAssertEqual(Policy.effectiveFolderWorkerLimit(settings: auto8, thermalState: .nominal), 4)
        XCTAssertEqual(Policy.effectiveFolderWorkerLimit(settings: auto8, thermalState: .fair), 4)
        XCTAssertEqual(Policy.effectiveFolderWorkerLimit(settings: auto8, thermalState: .serious), 2)
        XCTAssertEqual(Policy.effectiveFolderWorkerLimit(settings: auto8, thermalState: .critical), 1)

        let manual8 = Settings(isAutoEnabled: false, requestedWorkerCount: 8)
        XCTAssertEqual(Policy.effectiveFolderWorkerLimit(settings: manual8, thermalState: .serious), 4)
        XCTAssertEqual(Policy.effectiveFolderWorkerLimit(settings: manual8, thermalState: .critical), 1)

        let auto3 = Settings(isAutoEnabled: true, requestedWorkerCount: 3)
        XCTAssertEqual(Policy.effectiveFolderWorkerLimit(settings: auto3, thermalState: .nominal), 1)

        let auto1 = Settings(isAutoEnabled: true, requestedWorkerCount: 1)
        XCTAssertEqual(Policy.effectiveFolderWorkerLimit(settings: auto1, thermalState: .nominal), 1)
    }

    // MARK: - Persistence & migration

    private func makeIsolatedDefaults() throws -> UserDefaults {
        let suite = "ConcurrencyPolicyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
        }
        return defaults
    }

    func testMigrateLegacyPreferencePreservesUserIntent() {
        let auto = Persistence.migrateLegacyPreference(rawValue: "auto", activeProcessorCount: 6)
        XCTAssertEqual(auto, Settings(isAutoEnabled: true, requestedWorkerCount: 6))

        for (raw, count) in [("1", 1), ("2", 2), ("4", 4), ("8", 8)] {
            XCTAssertEqual(
                Persistence.migrateLegacyPreference(rawValue: raw, activeProcessorCount: 6),
                Settings(isAutoEnabled: false, requestedWorkerCount: count),
                "명시적 \(raw)개는 자동 꺼짐 + 요청 \(count)개로 옮겨야 합니다."
            )
        }

        // Robustness: whitespace/case, out-of-range numbers, garbage, nil.
        XCTAssertEqual(
            Persistence.migrateLegacyPreference(rawValue: " Auto ", activeProcessorCount: 4),
            Settings(isAutoEnabled: true, requestedWorkerCount: 4)
        )
        XCTAssertEqual(
            Persistence.migrateLegacyPreference(rawValue: "99", activeProcessorCount: 4),
            Settings(isAutoEnabled: false, requestedWorkerCount: 16)
        )
        XCTAssertNil(Persistence.migrateLegacyPreference(rawValue: "many", activeProcessorCount: 4))
        XCTAssertNil(Persistence.migrateLegacyPreference(rawValue: "", activeProcessorCount: 4))
        XCTAssertNil(Persistence.migrateLegacyPreference(rawValue: nil, activeProcessorCount: 4))
    }

    func testLoadWithoutAnyStoredValueUsesDefaultsAndWritesNewKeys() throws {
        let defaults = try makeIsolatedDefaults()

        let settings = Persistence.load(from: defaults, activeProcessorCount: 8)
        XCTAssertEqual(settings, Settings(isAutoEnabled: true, requestedWorkerCount: 8))
        XCTAssertEqual(defaults.bool(forKey: Persistence.autoEnabledKey), true)
        XCTAssertEqual(defaults.integer(forKey: Persistence.requestedWorkerCountKey), 8)
        XCTAssertNil(defaults.object(forKey: Persistence.legacyPreferenceKey))
    }

    func testLoadMigratesLegacyExplicitValueAndRemovesLegacyKey() throws {
        let defaults = try makeIsolatedDefaults()
        defaults.set("4", forKey: Persistence.legacyPreferenceKey)

        let settings = Persistence.load(from: defaults, activeProcessorCount: 8)
        XCTAssertEqual(settings, Settings(isAutoEnabled: false, requestedWorkerCount: 4))
        XCTAssertEqual(defaults.bool(forKey: Persistence.autoEnabledKey), false)
        XCTAssertEqual(defaults.integer(forKey: Persistence.requestedWorkerCountKey), 4)
        XCTAssertNil(defaults.object(forKey: Persistence.legacyPreferenceKey), "이전 키는 마이그레이션 후 제거되어야 합니다.")

        // Second load is stable and does not reapply migration.
        XCTAssertEqual(Persistence.load(from: defaults, activeProcessorCount: 8), settings)
    }

    func testLoadMigratesLegacyAutoValueToAutoWithProcessorDefault() throws {
        let defaults = try makeIsolatedDefaults()
        defaults.set("auto", forKey: Persistence.legacyPreferenceKey)

        let settings = Persistence.load(from: defaults, activeProcessorCount: 10)
        XCTAssertEqual(settings, Settings(isAutoEnabled: true, requestedWorkerCount: 10))
        XCTAssertNil(defaults.object(forKey: Persistence.legacyPreferenceKey))
    }

    func testLoadIgnoresUnknownLegacyValueAndFallsBackToDefaults() throws {
        let defaults = try makeIsolatedDefaults()
        defaults.set("bogus", forKey: Persistence.legacyPreferenceKey)

        let settings = Persistence.load(from: defaults, activeProcessorCount: 6)
        XCTAssertEqual(settings, Settings(isAutoEnabled: true, requestedWorkerCount: 6))
        XCTAssertNil(defaults.object(forKey: Persistence.legacyPreferenceKey))
    }

    func testNewKeysTakePrecedenceOverLegacyKey() throws {
        let defaults = try makeIsolatedDefaults()
        defaults.set("1", forKey: Persistence.legacyPreferenceKey)
        Persistence.save(Settings(isAutoEnabled: true, requestedWorkerCount: 12), to: defaults)

        let settings = Persistence.load(from: defaults, activeProcessorCount: 4)
        XCTAssertEqual(settings, Settings(isAutoEnabled: true, requestedWorkerCount: 12))
        XCTAssertNil(defaults.object(forKey: Persistence.legacyPreferenceKey), "새 키가 있으면 이전 키는 정리만 합니다.")
    }

    func testLoadFillsMissingHalfOfNewKeysFromDefaults() throws {
        let defaults = try makeIsolatedDefaults()
        defaults.set(false, forKey: Persistence.autoEnabledKey)

        let settings = Persistence.load(from: defaults, activeProcessorCount: 6)
        XCTAssertEqual(settings, Settings(isAutoEnabled: false, requestedWorkerCount: 6))
        XCTAssertEqual(defaults.integer(forKey: Persistence.requestedWorkerCountKey), 6)

        let defaults2 = try makeIsolatedDefaults()
        defaults2.set(3, forKey: Persistence.requestedWorkerCountKey)
        let settings2 = Persistence.load(from: defaults2, activeProcessorCount: 6)
        XCTAssertEqual(settings2, Settings(isAutoEnabled: true, requestedWorkerCount: 3))
        XCTAssertEqual(defaults2.bool(forKey: Persistence.autoEnabledKey), true)
    }

    func testLoadClampsOutOfRangeStoredRequestedCount() throws {
        let defaults = try makeIsolatedDefaults()
        defaults.set(true, forKey: Persistence.autoEnabledKey)
        defaults.set(0, forKey: Persistence.requestedWorkerCountKey)
        XCTAssertEqual(Persistence.load(from: defaults, activeProcessorCount: 4).requestedWorkerCount, 1)

        defaults.set(400, forKey: Persistence.requestedWorkerCountKey)
        XCTAssertEqual(Persistence.load(from: defaults, activeProcessorCount: 4).requestedWorkerCount, 16)
    }

    func testSaveRoundTrips() throws {
        let defaults = try makeIsolatedDefaults()
        let settings = Settings(isAutoEnabled: false, requestedWorkerCount: 7)
        Persistence.save(settings, to: defaults)
        XCTAssertEqual(Persistence.load(from: defaults, activeProcessorCount: 2), settings)
    }

    // MARK: - Depth grouping

    func testFolderDepthGroupingDeepestFirstAndDeterministicOrder() {
        let folders = [
            FolderEntry(url: URL(fileURLWithPath: "/root/parent/child_b"), depth: 2),
            FolderEntry(url: URL(fileURLWithPath: "/root/parent/child_a"), depth: 2),
            FolderEntry(url: URL(fileURLWithPath: "/root/parent"), depth: 1),
            FolderEntry(url: URL(fileURLWithPath: "/root/parent/child_a/leaf"), depth: 3),
            FolderEntry(url: URL(fileURLWithPath: "/root/other_parent"), depth: 1),
        ]

        let groups = FolderDepthGrouping.groupDeepestFirst(folders: folders)
        XCTAssertEqual(groups.count, 3)

        // Depth 3 (Deepest)
        XCTAssertEqual(groups[0].count, 1)
        XCTAssertEqual(groups[0][0].url.lastPathComponent, "leaf")
        XCTAssertEqual(groups[0][0].depth, 3)

        // Depth 2
        XCTAssertEqual(groups[1].count, 2)
        XCTAssertEqual(groups[1].map(\.url.lastPathComponent), ["child_a", "child_b"])
        XCTAssertTrue(groups[1].allSatisfy { $0.depth == 2 })

        // Depth 1
        XCTAssertEqual(groups[2].count, 2)
        XCTAssertEqual(groups[2].map(\.url.lastPathComponent), ["other_parent", "parent"])
        XCTAssertTrue(groups[2].allSatisfy { $0.depth == 1 })
    }

    func testFolderDepthGroupingEmptyAndSingleDepth() {
        XCTAssertTrue(FolderDepthGrouping.groupDeepestFirst(folders: []).isEmpty)

        let single = [FolderEntry(url: URL(fileURLWithPath: "/root/sub"), depth: 1)]
        let groups = FolderDepthGrouping.groupDeepestFirst(folders: single)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].count, 1)
    }
}
