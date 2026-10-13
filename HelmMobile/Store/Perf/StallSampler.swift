import Darwin
import Foundation
import MachO
import Synchronization

/// Watches the main thread from a thread of its own. When the main thread hasn't ticked
/// (`beat()`, every display frame) for `threshold`, it is busy: its stack is sampled every few
/// milliseconds until it ticks again, and the stall goes to the recorder with those samples.
///
/// Sampling suspends the main thread for a few microseconds and walks its frame pointers. Nothing
/// may allocate while it is suspended (it could hold the malloc lock), so the walk writes into a
/// buffer allocated up front and the samples become Swift arrays only after it resumes.
final class StallSampler: @unchecked Sendable {
    static let shared = StallSampler()

    private let lastBeat = Atomic<UInt64>(0)
    private let active = Atomic<Bool>(false)
    private var mainThread: thread_act_t = 0
    private var thread: Thread?

    /// About four frames at 120 Hz: short enough to catch a scroll hitch, long enough to skip noise.
    private let threshold = 0.032
    private let interval: useconds_t = 4_000
    private let maxDepth = 96
    private let maxSamples = 400
    private let buffer: UnsafeMutablePointer<UInt>

    private init() {
        buffer = .allocate(capacity: 96)
    }

    /// Called on the main thread.
    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        if mainThread == 0 { mainThread = pthread_mach_thread_np(pthread_self()) }
        beat()
        active.store(true, ordering: .releasing)
        guard thread == nil else { return }
        let thread = Thread { [unowned self] in run() }
        thread.name = "helm.stall-sampler"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    /// Paused in the background, where the display link stops and silence means nothing.
    func pause() { active.store(false, ordering: .releasing) }

    func beat() { lastBeat.store(mach_absolute_time(), ordering: .releasing) }

    private func run() {
        var stallStart: UInt64 = 0
        var samples: [[UInt]] = []
        while true {
            usleep(interval)
            guard active.load(ordering: .acquiring) else {
                stallStart = 0
                samples.removeAll()
                continue
            }
            let beat = lastBeat.load(ordering: .acquiring)
            let now = mach_absolute_time()
            let busy = now > beat && PerfClock.seconds(now - beat) > threshold
            // A new beat ends the stall being sampled (busy again means a new one started).
            if stallStart != 0, beat != stallStart {
                report(start: stallStart, end: beat, samples: samples)
                stallStart = 0
                samples = []
            }
            guard busy else { continue }
            if stallStart == 0 { stallStart = beat }
            if samples.count < maxSamples {
                let depth = capture()
                if depth > 0 { samples.append(Array(UnsafeBufferPointer(start: buffer, count: depth))) }
            }
        }
    }

    private func report(start: UInt64, end: UInt64, samples: [[UInt]]) {
        guard end > start, Perf.isOn else { return }
        PerfRecorder.shared.stall(start: PerfClock.seconds(start), end: PerfClock.seconds(end), samples: samples)
    }

    /// Strips pointer-authentication bits from a return address.
    private static let addressMask: UInt = 0x0000_000F_FFFF_FFFF

    /// The main thread's return addresses, innermost first, into `buffer`.
    private func capture() -> Int {
        #if arch(arm64)
        guard thread_suspend(mainThread) == KERN_SUCCESS else { return 0 }
        defer { thread_resume(mainThread) }
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                thread_get_state(mainThread, ARM_THREAD_STATE64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        var depth = 0
        buffer[depth] = UInt(state.__pc) & Self.addressMask
        depth += 1
        var frame = UInt(state.__fp)
        var record: (UInt, UInt) = (0, 0)
        let task = mach_task_self_
        while frame != 0, frame & 0xF == 0, depth < maxDepth {
            var read: vm_size_t = 0
            let ok = withUnsafeMutablePointer(to: &record) {
                vm_read_overwrite(task, vm_address_t(frame), vm_size_t(16), vm_address_t(UInt(bitPattern: $0)), &read)
            }
            guard ok == KERN_SUCCESS, record.1 != 0 else { break }
            buffer[depth] = record.1 & Self.addressMask
            depth += 1
            // Callers' frames sit higher on the stack.
            guard record.0 > frame else { break }
            frame = record.0
        }
        return depth
        #else
        return 0
        #endif
    }
}

/// Names for sampled addresses: the image and, outside the app's own (stripped) binary, the symbol.
enum PerfSymbols {
    struct Image: Codable, Sendable {
        var name: String
        var base: UInt
        var uuid: String?
    }

    struct Frame: Codable, Sendable {
        var image: String
        var offset: UInt
        var symbol: String?
    }

    static func resolve(_ addresses: Set<UInt>) -> (frames: [String: Frame], images: [Image]) {
        var frames: [String: Frame] = [:]
        var images: [UInt: Image] = [:]
        let appName = Bundle.main.executableURL?.lastPathComponent
        for address in addresses {
            var info = Dl_info()
            guard dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0, let base = info.dli_fbase else { continue }
            let path = info.dli_fname.map { String(cString: $0) } ?? "?"
            let name = (path as NSString).lastPathComponent
            let baseAddress = UInt(bitPattern: base)
            if images[baseAddress] == nil {
                images[baseAddress] = Image(name: name, base: baseAddress, uuid: uuid(of: base))
            }
            // The app's binary is stripped, so the nearest symbol dladdr finds would be a wrong one.
            let symbol = name == appName ? nil : info.dli_sname.map { String(cString: $0) }
            frames[String(address, radix: 16)] = Frame(image: name, offset: address - baseAddress, symbol: symbol)
        }
        return (frames, Array(images.values))
    }

    private static func uuid(of header: UnsafeMutableRawPointer) -> String? {
        let mach = header.load(as: mach_header_64.self)
        guard mach.magic == MH_MAGIC_64 else { return nil }
        var command = UnsafeRawPointer(header) + MemoryLayout<mach_header_64>.size
        for _ in 0..<mach.ncmds {
            let load = command.load(as: load_command.self)
            if load.cmd == UInt32(LC_UUID) {
                return UUID(uuid: command.load(as: uuid_command.self).uuid).uuidString
            }
            command += Int(load.cmdsize)
        }
        return nil
    }

    /// The app binary's build UUID, to find its dSYM.
    static var appUUID: String? {
        for index in 0..<_dyld_image_count() {
            guard let header = _dyld_get_image_header(index) else { continue }
            if header.pointee.filetype == UInt32(MH_EXECUTE) {
                return uuid(of: UnsafeMutableRawPointer(mutating: header))
            }
        }
        return nil
    }
}
