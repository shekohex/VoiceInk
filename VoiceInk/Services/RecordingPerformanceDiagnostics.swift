import Darwin
import Foundation
import OSLog

/// Correlates recording startup, UI responsiveness, and background model work.
/// Search exported logs for category `RecordingPerformance` or a specific `trace=`.
final class RecordingPerformanceDiagnostics: @unchecked Sendable {
    static let shared = RecordingPerformanceDiagnostics()

    private struct Trace: Sendable {
        let id: String
        let startedAtNanoseconds: UInt64
    }

    private struct ProcessMemorySnapshot {
        let residentBytes: UInt64
        let physicalFootprintBytes: UInt64
    }

    private let logger = Logger(
        subsystem: "com.prakashjoshipax.voiceink",
        category: "RecordingPerformance"
    )
    private let lock = NSLock()
    private var activeTrace: Trace?
    private var monitorTask: Task<Void, Never>?

    private init() {}

    func begin(trigger: String, panelStyle: String) {
        let trace = Trace(
            id: String(UUID().uuidString.prefix(8)),
            startedAtNanoseconds: DispatchTime.now().uptimeNanoseconds
        )

        lock.lock()
        let previousMonitorTask = monitorTask
        activeTrace = trace
        monitorTask = nil
        lock.unlock()

        previousMonitorTask?.cancel()
        log(
            trace: trace,
            event: "recording.request_received",
            details: "trigger=\(trigger) panel=\(panelStyle)"
        )
        startResponsivenessMonitor(for: trace)
    }

    func mark(_ event: String, details: String = "") {
        guard let trace = currentTrace() else { return }
        log(trace: trace, event: event, details: details)
    }

    func finish(
        _ event: String,
        details: String = "",
        lingerNanoseconds: UInt64 = 0
    ) {
        guard let trace = currentTrace() else { return }
        log(trace: trace, event: event, details: details)

        guard lingerNanoseconds > 0 else {
            close(trace)
            return
        }

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: lingerNanoseconds)
            self?.close(trace)
        }
    }

    private func close(_ trace: Trace) {
        lock.lock()
        guard activeTrace?.id == trace.id else {
            lock.unlock()
            return
        }
        activeTrace = nil
        let task = monitorTask
        monitorTask = nil
        lock.unlock()
        task?.cancel()
    }

    private func startResponsivenessMonitor(for trace: Trace) {
        let task = Task { @MainActor [weak self] in
            guard let self else { return }

            let heartbeatNanoseconds: UInt64 = 100_000_000
            let stallThresholdMilliseconds = 50.0
            var expectedNanoseconds = DispatchTime.now().uptimeNanoseconds
            var previousSampleNanoseconds = expectedNanoseconds
            var previousCPUTime = self.processCPUTimeSeconds()
            var resourceSampleIndex = 0
            var heartbeatIndex = 0
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: heartbeatNanoseconds)
                } catch {
                    return
                }

                guard self.isActive(trace) else { return }

                heartbeatIndex += 1
                expectedNanoseconds += heartbeatNanoseconds
                let now = DispatchTime.now().uptimeNanoseconds
                let delayMilliseconds =
                    now > expectedNanoseconds
                    ? Double(now - expectedNanoseconds) / 1_000_000
                    : 0

                if delayMilliseconds >= stallThresholdMilliseconds {
                    self.log(
                        trace: trace,
                        event: "main_actor.stall",
                        details: String(
                            format: "heartbeat=%d delay_ms=%.2f",
                            heartbeatIndex,
                            delayMilliseconds
                        )
                    )
                }

                guard heartbeatIndex.isMultiple(of: 10) else {
                    expectedNanoseconds = now
                    continue
                }

                resourceSampleIndex += 1
                let cpuTime = self.processCPUTimeSeconds()
                let wallSeconds = Double(now - previousSampleNanoseconds) / 1_000_000_000
                let cpuPercent =
                    wallSeconds > 0
                    ? max(0, cpuTime - previousCPUTime) / wallSeconds * 100
                    : 0

                self.log(
                    trace: trace,
                    event: "resource.sample",
                    details: String(
                        format: "sample=%d process_cpu_pct=%.1f",
                        resourceSampleIndex,
                        cpuPercent
                    )
                )
                expectedNanoseconds = now
                previousSampleNanoseconds = now
                previousCPUTime = cpuTime
            }
        }

        lock.lock()
        guard activeTrace?.id == trace.id else {
            lock.unlock()
            task.cancel()
            return
        }
        monitorTask = task
        lock.unlock()
    }

    private func currentTrace() -> Trace? {
        lock.lock()
        let trace = activeTrace
        lock.unlock()
        return trace
    }

    private func isActive(_ trace: Trace) -> Bool {
        lock.lock()
        let isActive = activeTrace?.id == trace.id
        lock.unlock()
        return isActive
    }

    private func log(trace: Trace, event: String, details: String) {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsedMilliseconds = Double(now - trace.startedAtNanoseconds) / 1_000_000
        let memory = processMemorySnapshot()
        let residentMegabytes = Double(memory.residentBytes) / 1_048_576
        let footprintMegabytes = Double(memory.physicalFootprintBytes) / 1_048_576
        let suffix = details.isEmpty ? "" : " \(details)"
        let message = String(
            format:
                "trace=%@ event=%@ elapsed_ms=%.2f rss_mb=%.1f footprint_mb=%.1f%@",
            trace.id,
            event,
            elapsedMilliseconds,
            residentMegabytes,
            footprintMegabytes,
            suffix
        )
        logger.notice("\(message, privacy: .public)")
    }

    private func processMemorySnapshot() -> ProcessMemorySnapshot {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    $0,
                    &count
                )
            }
        }

        guard result == KERN_SUCCESS else {
            return ProcessMemorySnapshot(residentBytes: 0, physicalFootprintBytes: 0)
        }
        return ProcessMemorySnapshot(
            residentBytes: info.resident_size,
            physicalFootprintBytes: info.phys_footprint
        )
    }

    private func processCPUTimeSeconds() -> Double {
        var info = task_thread_times_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_thread_times_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_THREAD_TIMES_INFO),
                    $0,
                    &count
                )
            }
        }

        guard result == KERN_SUCCESS else { return 0 }
        let userSeconds =
            Double(info.user_time.seconds)
            + Double(info.user_time.microseconds) / 1_000_000
        let systemSeconds =
            Double(info.system_time.seconds)
            + Double(info.system_time.microseconds) / 1_000_000
        return userSeconds + systemSeconds
    }
}
