import Foundation
import XCTest
@testable import NasFinderSuperThumbnailMac

/// Verifies that the worker limit can change while a job is running:
/// - lowering never cancels in-flight items and only blocks further starts,
/// - raising starts queued items immediately (without waiting for a completion),
/// - thermal throttling/recovery moves the auto limit down and back up.
@MainActor
final class DynamicConcurrencyTests: XCTestCase {
    // MARK: - Scheduler

    func testRaisingLimitStartsQueuedItemsImmediately() async throws {
        let harness = SchedulerHarness(limit: 1)
        let run = harness.run(itemCount: 4)

        try await waitUntil("첫 항목 시작") { harness.currentInFlight == 1 }
        XCTAssertTrue(harness.outcomes.isEmpty)

        // Raise while item 0 is still blocked: items 1 and 2 must start without any completion.
        harness.setLimit(3)
        try await waitUntil("제한 상향 즉시 반영") { harness.currentInFlight == 3 }
        XCTAssertTrue(harness.outcomes.isEmpty, "완료 없이도 새 항목이 시작되어야 합니다.")
        XCTAssertEqual(harness.maxInFlight, 3)

        await harness.gate.releaseAll(count: 4)
        await run.value

        XCTAssertEqual(harness.outcomes.sorted(), [0, 1, 2, 3])
        XCTAssertEqual(harness.maxInFlight, 3)
        XCTAssertEqual(harness.currentInFlight, 0)
    }

    func testLoweringLimitKeepsInFlightWorkAndBlocksNewStarts() async throws {
        let harness = SchedulerHarness(limit: 3)
        let run = harness.run(itemCount: 5)

        try await waitUntil("초기 3개 시작") { harness.currentInFlight == 3 }

        harness.setLimit(1)
        try await Task.sleep(for: .milliseconds(100))
        // Lowering must not cancel anything: still 3 in flight, nothing finished.
        XCTAssertEqual(harness.currentInFlight, 3)
        XCTAssertTrue(harness.outcomes.isEmpty)

        await harness.gate.release(0)
        try await waitUntil("항목 0 완료") { harness.outcomes.count == 1 }
        XCTAssertEqual(harness.currentInFlight, 2, "제한(1)보다 많이 실행 중이면 새 항목을 시작하지 않아야 합니다.")

        await harness.gate.release(1)
        try await waitUntil("항목 1 완료") { harness.outcomes.count == 2 }
        XCTAssertEqual(harness.currentInFlight, 1)

        await harness.gate.release(2)
        try await waitUntil("항목 2 완료 후 다음 항목 시작") {
            harness.outcomes.count == 3 && harness.currentInFlight == 1
        }
        XCTAssertEqual(harness.startedItems, [0, 1, 2, 3], "자리가 나야 다음 항목(3)이 순서대로 시작됩니다.")

        await harness.gate.releaseAll(count: 5)
        await run.value

        XCTAssertEqual(harness.outcomes, [0, 1, 2, 3, 4], "이미 시작한 항목이 취소되지 않고 모두 정상 완료되어야 합니다.")
        XCTAssertEqual(harness.maxInFlight, 3)
    }

    func testAutoModeFollowsThermalThrottleAndRecovery() async throws {
        let harness = SchedulerHarness(limit: 0)
        harness.thermalState = .nominal
        let settings = SuperThumbnailConcurrencySettings(isAutoEnabled: true, requestedWorkerCount: 4)
        harness.limitProvider = { thermal in
            SuperThumbnailConcurrencyPolicy.effectiveWorkerLimit(settings: settings, thermalState: thermal)
        }
        let run = harness.run(itemCount: 10)

        try await waitUntil("요청한 4개 시작") { harness.currentInFlight == 4 }

        // Serious thermal pressure: limit halves to 2, in-flight items keep running.
        harness.setThermalState(.serious)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(harness.currentInFlight, 4)

        for id in 0..<2 {
            await harness.gate.release(id)
            try await waitUntil("항목 \(id) 완료") { harness.outcomes.count == id + 1 }
            XCTAssertEqual(harness.currentInFlight, 3 - id, "발열로 절반(2개)으로 줄면 2개 이하가 될 때까지 새 항목을 시작하지 않아야 합니다.")
        }
        XCTAssertEqual(harness.startedItems.count, 4)

        await harness.gate.release(2)
        try await waitUntil("절반 제한(2개) 하에서 자리가 나면 1개 시작") {
            harness.outcomes.count == 3 && harness.currentInFlight == 2
        }
        XCTAssertEqual(harness.startedItems.count, 5)

        // Critical: limit is 1, again nothing new starts until only one item remains.
        harness.setThermalState(.critical)
        await harness.gate.release(3)
        try await waitUntil("항목 3 완료") { harness.outcomes.count == 4 }
        XCTAssertEqual(harness.currentInFlight, 1, "critical 발열에서는 1개만 실행해야 합니다.")
        XCTAssertEqual(harness.startedItems.count, 5)

        // Recovery: limit returns to the requested 4 and queued items start right away.
        harness.setThermalState(.nominal)
        try await waitUntil("자원 회복 시 요청한 4개로 복귀") { harness.currentInFlight == 4 }
        XCTAssertEqual(harness.outcomes.count, 4, "완료 없이도 즉시 추가 시작되어야 합니다.")

        await harness.gate.releaseAll(count: 10)
        await run.value
        XCTAssertEqual(harness.outcomes.sorted(), Array(0..<10))
        XCTAssertEqual(harness.maxInFlight, 4)
    }

    func testManualModeKeepsRequestedUnderSeriousButDropsToOneUnderCritical() async throws {
        let harness = SchedulerHarness(limit: 0)
        harness.thermalState = .nominal
        let settings = SuperThumbnailConcurrencySettings(isAutoEnabled: false, requestedWorkerCount: 3)
        harness.limitProvider = { thermal in
            SuperThumbnailConcurrencyPolicy.effectiveWorkerLimit(settings: settings, thermalState: thermal)
        }
        let run = harness.run(itemCount: 6)

        try await waitUntil("요청한 3개 시작") { harness.currentInFlight == 3 }

        // Serious: Auto off honors the user's number, so a completion is refilled immediately.
        harness.setThermalState(.serious)
        await harness.gate.release(0)
        try await waitUntil("serious에서도 3개 유지") {
            harness.outcomes.count == 1 && harness.currentInFlight == 3
        }
        XCTAssertEqual(harness.startedItems.count, 4)

        // Critical is never ignored: drain down to 1.
        harness.setThermalState(.critical)
        await harness.gate.release(1)
        try await waitUntil("항목 1 완료") { harness.outcomes.count == 2 }
        XCTAssertEqual(harness.currentInFlight, 2)
        await harness.gate.release(2)
        try await waitUntil("항목 2 완료") { harness.outcomes.count == 3 }
        XCTAssertEqual(harness.currentInFlight, 1, "critical에서는 자동 여부와 관계없이 1개만 실행해야 합니다.")
        XCTAssertEqual(harness.startedItems.count, 4)

        harness.setThermalState(.nominal)
        try await waitUntil("회복 시 3개로 복귀") { harness.currentInFlight == 3 }

        await harness.gate.releaseAll(count: 6)
        await run.value
        XCTAssertEqual(harness.outcomes.sorted(), Array(0..<6))
        XCTAssertEqual(harness.maxInFlight, 3)
    }

    func testPausedBeforeStartWaitsForResumeInsteadOfFinishing() async throws {
        let harness = SchedulerHarness(limit: 2)
        harness.isPaused = true
        let run = harness.run(itemCount: 3)

        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(harness.startedItems.isEmpty)
        XCTAssertTrue(harness.outcomes.isEmpty)

        harness.isPaused = false
        try await waitUntil("재개 후 시작") { harness.currentInFlight == 2 }

        await harness.gate.releaseAll(count: 3)
        await run.value
        XCTAssertEqual(harness.outcomes.sorted(), [0, 1, 2])
    }

    func testCancellationStopsNewStartsButDeliveredOutcomesStay() async throws {
        let harness = SchedulerHarness(limit: 1)
        let run = harness.run(itemCount: 4)

        try await waitUntil("항목 0 시작") { harness.currentInFlight == 1 }
        await harness.gate.release(0)
        try await waitUntil("항목 0 완료, 항목 1 시작") {
            harness.outcomes.count == 1 && harness.startedItems.count == 2
        }

        run.cancel()
        // The gated work ignores cancellation, so item 1 only finishes when released.
        await harness.gate.release(1)
        await run.value

        XCTAssertEqual(harness.outcomes, [0], "취소 후에는 결과를 반영하지 않지만 이미 반영된 결과는 유지됩니다.")
        XCTAssertEqual(harness.startedItems, [0, 1], "취소 후 새 항목을 시작하지 않아야 합니다.")
        XCTAssertEqual(harness.currentInFlight, 0)
    }

    // MARK: - Signal

    func testSignalReturnsImmediatelyForStaleGenerationAndReleasesOnCancel() async throws {
        let signal = SuperThumbnailWorkerLimitSignal()
        let generation = signal.generation
        signal.notifyChanged()
        XCTAssertEqual(signal.generation, generation + 1)

        // Stale generation: must not suspend.
        let stale = Task { await signal.waitForChange(after: generation) }
        try await waitUntilTaskFinishes(stale, "오래된 세대는 즉시 반환")

        // Current generation: suspends until cancelled.
        let waiting = Task { await signal.waitForChange(after: signal.generation) }
        try await Task.sleep(for: .milliseconds(50))
        waiting.cancel()
        try await waitUntilTaskFinishes(waiting, "취소 시 대기 해제")

        // Current generation: resumed by notifyChanged.
        let notified = Task { await signal.waitForChange(after: signal.generation) }
        try await Task.sleep(for: .milliseconds(50))
        signal.notifyChanged()
        try await waitUntilTaskFinishes(notified, "변경 알림 시 대기 해제")
    }

    // MARK: - Model wiring

    func testModelThermalUpdateChangesEffectiveLimitAndWakesScheduler() throws {
        let (model, _) = try makeIsolatedModel()
        model.setConcurrencySettings(SuperThumbnailConcurrencySettings(isAutoEnabled: true, requestedWorkerCount: 8))
        model.updateThermalState(.nominal)
        let generation = model.limitSignal.generation

        XCTAssertEqual(model.effectiveWorkerLimit(), 8)
        XCTAssertEqual(model.effectiveFolderWorkerLimit(), 4)
        XCTAssertFalse(model.isThermalThrottled)
        XCTAssertFalse(model.isReducedByThermalPressure)

        model.updateThermalState(.serious)
        XCTAssertTrue(model.isThermalThrottled)
        XCTAssertTrue(model.isReducedByThermalPressure)
        XCTAssertEqual(model.effectiveWorkerLimit(), 4)
        XCTAssertEqual(model.effectiveFolderWorkerLimit(), 2)
        XCTAssertEqual(model.requestedWorkerCount, 8, "발열 조절은 표시되는 요청 개수를 바꾸지 않아야 합니다.")
        XCTAssertEqual(model.limitSignal.generation, generation + 1)

        // Same state again: no spurious wake-up.
        model.updateThermalState(.serious)
        XCTAssertEqual(model.limitSignal.generation, generation + 1)

        model.updateThermalState(.critical)
        XCTAssertEqual(model.effectiveWorkerLimit(), 1)
        XCTAssertEqual(model.effectiveFolderWorkerLimit(), 1)
        XCTAssertEqual(model.limitSignal.generation, generation + 2)

        // Recovery restores the requested number.
        model.updateThermalState(.nominal)
        XCTAssertEqual(model.effectiveWorkerLimit(), 8)
        XCTAssertEqual(model.effectiveFolderWorkerLimit(), 4)
        XCTAssertFalse(model.isReducedByThermalPressure)
        XCTAssertEqual(model.limitSignal.generation, generation + 3)
    }

    func testModelAutoOffKeepsRequestedUnderSeriousAndClampsUnderCritical() throws {
        let (model, _) = try makeIsolatedModel()
        model.setConcurrencySettings(SuperThumbnailConcurrencySettings(isAutoEnabled: false, requestedWorkerCount: 6))
        model.updateThermalState(.serious)
        XCTAssertEqual(model.effectiveWorkerLimit(), 6)
        XCTAssertEqual(model.effectiveFolderWorkerLimit(), 3)
        XCTAssertFalse(model.isReducedByThermalPressure)

        model.updateThermalState(.critical)
        XCTAssertEqual(model.effectiveWorkerLimit(), 1)
        XCTAssertEqual(model.effectiveFolderWorkerLimit(), 1)
        XCTAssertTrue(model.isReducedByThermalPressure)
    }

    func testModelPlusMinusChangeOnlyRequestedNumberPersistImmediatelyAndWakeScheduler() throws {
        let (model, defaults) = try makeIsolatedModel()
        model.setConcurrencySettings(SuperThumbnailConcurrencySettings(isAutoEnabled: true, requestedWorkerCount: 4))
        model.updateThermalState(.nominal)
        let generation = model.limitSignal.generation

        model.incrementRequestedWorkerCount()
        XCTAssertEqual(model.requestedWorkerCount, 5)
        XCTAssertTrue(model.isAutoConcurrencyEnabled, "+는 자동 플래그를 바꾸지 않아야 합니다.")
        XCTAssertEqual(model.effectiveWorkerLimit(), 5)
        XCTAssertEqual(model.effectiveFolderWorkerLimit(), 2)
        XCTAssertEqual(model.limitSignal.generation, generation + 1)
        XCTAssertEqual(defaults.integer(forKey: SuperThumbnailConcurrencyPersistence.requestedWorkerCountKey), 5)
        XCTAssertEqual(defaults.bool(forKey: SuperThumbnailConcurrencyPersistence.autoEnabledKey), true)

        model.decrementRequestedWorkerCount()
        model.decrementRequestedWorkerCount()
        XCTAssertEqual(model.requestedWorkerCount, 3)
        XCTAssertEqual(model.effectiveFolderWorkerLimit(), 1)
        XCTAssertEqual(model.limitSignal.generation, generation + 3)
        XCTAssertEqual(defaults.integer(forKey: SuperThumbnailConcurrencyPersistence.requestedWorkerCountKey), 3)

        // Auto toggle is independent of the number and also persists immediately.
        model.setAutoConcurrencyEnabled(false)
        XCTAssertFalse(model.isAutoConcurrencyEnabled)
        XCTAssertEqual(model.requestedWorkerCount, 3)
        XCTAssertEqual(defaults.bool(forKey: SuperThumbnailConcurrencyPersistence.autoEnabledKey), false)
        XCTAssertEqual(model.limitSignal.generation, generation + 4)

        // A fresh model on the same defaults restores exactly what was persisted.
        let restored = SuperThumbnailMacModel(defaults: defaults)
        XCTAssertEqual(
            restored.concurrencySettings,
            SuperThumbnailConcurrencySettings(isAutoEnabled: false, requestedWorkerCount: 3)
        )
    }

    func testModelPlusMinusStopAtSupportedRangeWithoutSpuriousWakeups() throws {
        let (model, _) = try makeIsolatedModel()
        let range = SuperThumbnailConcurrencyPolicy.supportedWorkerRange

        model.setRequestedWorkerCount(range.upperBound)
        XCTAssertFalse(model.canIncrementRequestedWorkerCount)
        XCTAssertTrue(model.canDecrementRequestedWorkerCount)
        let atMax = model.limitSignal.generation
        model.incrementRequestedWorkerCount()
        XCTAssertEqual(model.requestedWorkerCount, range.upperBound)
        XCTAssertEqual(model.limitSignal.generation, atMax, "상한에서 +는 아무것도 바꾸지 않아야 합니다.")

        model.setRequestedWorkerCount(range.lowerBound)
        XCTAssertTrue(model.canIncrementRequestedWorkerCount)
        XCTAssertFalse(model.canDecrementRequestedWorkerCount)
        let atMin = model.limitSignal.generation
        model.decrementRequestedWorkerCount()
        XCTAssertEqual(model.requestedWorkerCount, range.lowerBound)
        XCTAssertEqual(model.limitSignal.generation, atMin, "하한에서 −는 아무것도 바꾸지 않아야 합니다.")
        XCTAssertEqual(model.effectiveFolderWorkerLimit(), 1, "요청 1개일 때 폴더 최소 1개")
    }

    func testModelMigratesLegacyPreferenceOnInit() throws {
        let (_, defaults) = try makeIsolatedModel()
        defaults.removeObject(forKey: SuperThumbnailConcurrencyPersistence.autoEnabledKey)
        defaults.removeObject(forKey: SuperThumbnailConcurrencyPersistence.requestedWorkerCountKey)
        defaults.set("2", forKey: SuperThumbnailConcurrencyPersistence.legacyPreferenceKey)

        let model = SuperThumbnailMacModel(defaults: defaults)
        XCTAssertFalse(model.isAutoConcurrencyEnabled)
        XCTAssertEqual(model.requestedWorkerCount, 2)
        XCTAssertNil(defaults.object(forKey: SuperThumbnailConcurrencyPersistence.legacyPreferenceKey))
    }

    // MARK: - Helpers

    /// Blocks each work item until the test explicitly releases it, making concurrency observable.
    private actor Gate {
        private var released: Set<Int> = []
        private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]

        func wait(_ id: Int) async {
            if released.contains(id) { return }
            await withCheckedContinuation { continuation in
                waiters[id] = continuation
            }
        }

        func release(_ id: Int) {
            released.insert(id)
            waiters.removeValue(forKey: id)?.resume()
        }

        func releaseAll(count: Int) {
            for id in 0..<count {
                release(id)
            }
        }
    }

    @MainActor
    private final class SchedulerHarness {
        var limit: Int
        var isPaused = false
        var thermalState: ProcessInfo.ThermalState = .nominal
        /// When set, overrides `limit` with a thermal-aware policy.
        var limitProvider: ((ProcessInfo.ThermalState) -> Int)?
        private(set) var inFlightHistory: [Int] = []
        private(set) var startedItems: [Int] = []
        private(set) var outcomes: [Int] = []
        let signal = SuperThumbnailWorkerLimitSignal()
        let gate = Gate()

        init(limit: Int) {
            self.limit = limit
        }

        var currentInFlight: Int { inFlightHistory.last ?? 0 }
        var maxInFlight: Int { inFlightHistory.max() ?? 0 }

        func setLimit(_ value: Int) {
            limit = value
            signal.notifyChanged()
        }

        func setThermalState(_ state: ProcessInfo.ThermalState) {
            thermalState = state
            signal.notifyChanged()
        }

        private func currentLimit() -> Int {
            limitProvider?(thermalState) ?? limit
        }

        func run(itemCount: Int) -> Task<Void, Never> {
            Task { @MainActor in
                await SuperThumbnailDynamicScheduler.run(
                    items: Array(0..<itemCount),
                    signal: self.signal,
                    limit: { self.currentLimit() },
                    isPaused: { self.isPaused },
                    onInFlightChange: { count in
                        if count > self.currentInFlight {
                            self.startedItems.append(self.startedItems.count)
                        }
                        self.inFlightHistory.append(count)
                    },
                    work: { [gate = self.gate] id in
                        await gate.wait(id)
                        return id
                    },
                    onOutcome: { id in
                        self.outcomes.append(id)
                    }
                )
            }
        }
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 5,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                XCTFail("시간 초과: \(description)")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor
    private final class CompletionFlag {
        var isSet = false
    }

    private func waitUntilTaskFinishes(
        _ task: Task<Void, Never>,
        _ description: String,
        timeout: TimeInterval = 5
    ) async throws {
        let flag = CompletionFlag()
        Task { @MainActor in
            await task.value
            flag.isSet = true
        }
        try await waitUntil(description, timeout: timeout) { flag.isSet }
    }

    /// Creates a model backed by a throw-away `UserDefaults` suite so tests never touch the user's
    /// real settings (concurrency keys, last folder, …).
    private func makeIsolatedModel() throws -> (SuperThumbnailMacModel, UserDefaults) {
        let suite = "DynamicConcurrencyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
        }
        return (SuperThumbnailMacModel(defaults: defaults), defaults)
    }
}
