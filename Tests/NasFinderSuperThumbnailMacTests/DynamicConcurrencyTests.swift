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
        harness.limitProvider = { thermal in
            SuperThumbnailConcurrencyPolicy.effectiveWorkerLimit(
                preference: .auto,
                isNetworkOrRemovable: false,
                thermalState: thermal
            )
        }
        let run = harness.run(itemCount: 8)

        try await waitUntil("로컬 자동 상한 4개 시작") { harness.currentInFlight == 4 }

        // Serious thermal pressure: limit becomes 1, in-flight items keep running.
        harness.setThermalState(.serious)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(harness.currentInFlight, 4)

        for id in 0..<3 {
            await harness.gate.release(id)
            try await waitUntil("항목 \(id) 완료") { harness.outcomes.count == id + 1 }
            XCTAssertEqual(harness.currentInFlight, 3 - id, "발열 제한 중에는 새 항목을 시작하지 않아야 합니다.")
        }
        await harness.gate.release(3)
        try await waitUntil("발열 제한 하에서 1개만 실행") {
            harness.outcomes.count == 4 && harness.currentInFlight == 1
        }
        XCTAssertEqual(harness.startedItems.count, 5)

        // Recovery: limit returns to 4 and queued items start right away.
        harness.setThermalState(.nominal)
        try await waitUntil("자원 회복 시 자동 상한 4개로 복귀") { harness.currentInFlight == 4 }
        XCTAssertEqual(harness.outcomes.count, 4, "완료 없이도 즉시 추가 시작되어야 합니다.")

        await harness.gate.releaseAll(count: 8)
        await run.value
        XCTAssertEqual(harness.outcomes.sorted(), Array(0..<8))
        XCTAssertEqual(harness.maxInFlight, 4)
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

    func testModelThermalUpdateChangesEffectiveLimitAndWakesScheduler() {
        withIsolatedPreference { model in
            model.setConcurrencyPreference(.auto)
            model.updateThermalState(.nominal)
            let generation = model.limitSignal.generation

            XCTAssertEqual(model.effectiveWorkerLimit(isNetworkOrRemovable: false), 4)
            XCTAssertEqual(model.effectiveWorkerLimit(isNetworkOrRemovable: true), 2)
            XCTAssertFalse(model.isThermalThrottled)

            model.updateThermalState(.serious)
            XCTAssertTrue(model.isThermalThrottled)
            XCTAssertEqual(model.effectiveWorkerLimit(isNetworkOrRemovable: false), 1)
            XCTAssertEqual(model.effectiveFolderWorkerLimit(isNetworkOrRemovable: false), 1)
            XCTAssertEqual(model.limitSignal.generation, generation + 1)

            // Same state again: no spurious wake-up.
            model.updateThermalState(.serious)
            XCTAssertEqual(model.limitSignal.generation, generation + 1)

            // Recovery restores the auto ceiling.
            model.updateThermalState(.nominal)
            XCTAssertEqual(model.effectiveWorkerLimit(isNetworkOrRemovable: false), 4)
            XCTAssertEqual(model.effectiveFolderWorkerLimit(isNetworkOrRemovable: false), 2)
            XCTAssertEqual(model.limitSignal.generation, generation + 2)
        }
    }

    func testModelPreferenceChangeWakesScheduler() {
        withIsolatedPreference { model in
            model.updateThermalState(.nominal)
            let generation = model.limitSignal.generation

            model.setConcurrencyPreference(.eight)
            XCTAssertEqual(model.effectiveWorkerLimit(isNetworkOrRemovable: true), 8)
            XCTAssertEqual(model.limitSignal.generation, generation + 1)

            model.setConcurrencyPreference(.one)
            XCTAssertEqual(model.effectiveWorkerLimit(isNetworkOrRemovable: false), 1)
            XCTAssertEqual(model.limitSignal.generation, generation + 2)
        }
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

    /// Runs `body` with a fresh model and restores the persisted worker preference afterwards so
    /// tests never change the user's real setting.
    private func withIsolatedPreference(_ body: (SuperThumbnailMacModel) -> Void) {
        let defaults = UserDefaults.standard
        let key = "macSuperThumbnail.concurrencyPreference"
        let previous = defaults.string(forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        body(SuperThumbnailMacModel())
    }
}
