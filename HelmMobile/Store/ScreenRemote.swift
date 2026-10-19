import AVFoundation
import CoreMedia
import Foundation
import UIKit
import Observation

/// The computer's screen on the phone (experimental): H.264 from Helm's `/api/helm/screen`
/// shown by a sample-buffer layer, and the phone's trackpad, clicks and keys sent back.
/// The video leaves the cursor out; the phone draws it at `cursor`, so it moves with the finger
/// at once instead of waiting for the picture.
@MainActor
@Observable
final class ScreenRemote {
    enum Phase: Equatable {
        case connecting
        case live
        case failed(String)
    }

    enum Button: String { case left, right, middle }

    /// Mac modifier keys, as the helper names them.
    enum Modifier: String, CaseIterable { case cmd, alt, ctrl, shift }

    /// One of the computer's displays, in its global points.
    struct Display: Identifiable, Equatable {
        let id: Int
        let name: String
        let frame: CGRect
        let isMain: Bool
        /// The one the computer added for this iPad.
        let isVirtual: Bool
    }

    /// What to show: a display, all of them side by side, or one the computer adds for this iPad.
    enum Shown: Hashable {
        case main, display(Int), all, virtual
    }

    /// A window on one of the computer's other displays, which can be brought to this iPad's.
    struct RemoteWindow: Identifiable, Equatable {
        let id: Int
        let pid: Int
        let app: String
        let title: String
        /// The display it's on.
        let display: Int
    }

    let environment: EnvironmentSession
    private(set) var phase = Phase.connecting
    /// The computer's display in points; zero until it says.
    private(set) var desktopSize = CGSize.zero
    /// Where the cursor is on the computer, in its points from the top-left.
    private(set) var cursor = CGPoint.zero
    /// Something works only partly, e.g. the picture comes but the computer won't take clicks yet.
    private(set) var notice: String?
    /// nil is an older helper which does not report session state.
    private(set) var isLocked: Bool?
    private(set) var lockStateAvailable = false
    private(set) var unlockEnabled = false
    /// The Mac user's full name, for the login card (an older helper sends none).
    private(set) var lockUser: String?
    private(set) var unlockInProgress = false
    private(set) var unlockMessage: String?
    @ObservationIgnored private var unlockTimeout: Task<Void, Never>?
    /// A password typed for this attempt, held only until the Mac answers: if it unlocks, the
    /// phone offers to keep it for Face ID (`saveOffer`); otherwise it's dropped.
    @ObservationIgnored private var typedPassword: String?
    /// This attempt used the password saved for Face ID.
    @ObservationIgnored private var usedSaved = false
    /// A typed password that just unlocked the Mac, until the person says whether to keep it.
    var saveOffer: PasswordSaveOffer?

    /// A password for this Mac is saved behind Face ID and still worked last time.
    var canUnlockWithFaceID: Bool {
        MacSecret.has(.mac, environmentId: environment.id) && !MacSecret.isStale(.mac, environmentId: environment.id)
    }

    /// Bumped when the first picture arrives (the view fades the placeholder out).
    private(set) var framesShown = 0
    /// The computer's arrow as it is now (an I-beam over text, a hand over a link); nil draws a
    /// plain arrow (an older Helm doesn't send it).
    private(set) var cursorShape: CursorShape?

    struct CursorShape: Equatable {
        let image: UIImage
        /// In the computer's points.
        let size: CGSize
        let hotSpot: CGPoint
    }

    /// This connection uses the away-from-home settings.
    private(set) var isAway = false

    /// The computer's displays; empty until it says (an older Helm never does).
    private(set) var displays: [Display] = []
    /// What the video shows now: `.display` or `.all`, nil until the computer says.
    private(set) var shown: Shown?

    /// The other displays' windows, front to back; nil while the computer lists them.
    private(set) var windows: [RemoteWindow]?
    /// Each app's icon, by its process.
    private(set) var windowIcons: [Int: UIImage] = [:]

    /// What was asked for: settings' choice at first, then the toolbar's, kept across reconnects.
    @ObservationIgnored private var wanted: Shown
    /// The screen's size here in points; the separate display is made from it.
    @ObservationIgnored private var viewSize = CGSize.zero
    @ObservationIgnored private var sentVirtualSize = CGSize.zero
    @ObservationIgnored private var resizeTask: Task<Void, Never>?
    @ObservationIgnored private let audio = ScreenAudio()
    /// Copied text goes both ways (settings).
    @ObservationIgnored let sharesClipboard = UserDefaults.standard.object(forKey: PhonePreferences.screenClipboardKey) as? Bool ?? true

    /// Decodes and draws the video; the view places it.
    @ObservationIgnored let layer = AVSampleBufferDisplayLayer()
    @ObservationIgnored private var task: URLSessionWebSocketTask?
    @ObservationIgnored private var format: CMVideoFormatDescription?
    /// While the finger moves the cursor, the computer's reports of it lag behind and are ignored.
    @ObservationIgnored private var movedLocallyAt = Date.distantPast
    @ObservationIgnored private var buttonHeld = false

    init(environment: EnvironmentSession) {
        self.environment = environment
        wanted = switch ScreenDisplayChoice.current {
        case .main: .main
        case .virtual: .virtual
        case .all: .all
        }
        layer.videoGravity = .resize
        NetworkPath.warmUp()
    }

    /// The computer can add a display for this iPad.
    var canAddVirtual: Bool {
        UIDevice.current.userInterfaceIdiom == .pad && !displays.isEmpty
    }

    var virtualDisplay: Display? { displays.first(where: \.isVirtual) }

    // MARK: Connection

    func connect() async {
        disconnect()
        phase = .connecting
        notice = nil
        do {
            try await environment.waitUntilLive()
            let http = environment.http
            let ticket = try await http.webSocketTicket()
            let task = HelmHTTP.session.webSocketTask(with: http.screenSocketURL(ticket: ticket))
            task.maximumMessageSize = 16 * 1024 * 1024
            self.task = task
            task.resume()
            // Home or away: each has its own quality, frame rate and resolution.
            let profile = ScreenStreamProfile.current(onThisNetwork: environment.isOnThisNetwork)
            isAway = profile.isAway
            let quality = profile.quality, resolution = profile.resolution
            let fps = profile.frameRate.fps
            // The bitrate is per 60 frames a second: 120 gets twice as many bits.
            let bitrate = quality.megabitsPer60 * 1_000_000 * fps / 60
            var start: [String: JSON] = [
                "t": "start", "maxWidth": 4096, "fps": .number(Double(fps)), "bitrate": .number(Double(bitrate)),
                "hevc": true, "maxScale": .number(Double(resolution.maxScale)), "display": displayValue(wanted),
                "name": .string("\(UIDevice.current.localizedModel) (Helm)"),
                "audio": .bool(UserDefaults.standard.bool(forKey: PhonePreferences.screenSoundKey)),
                "clipboard": .bool(sharesClipboard),
                "keepDisplay": .number(Double((UserDefaults.standard.string(forKey: PhonePreferences.screenKeepDisplayKey)
                    .flatMap(ScreenKeepDisplay.init(rawValue:)) ?? .short).seconds)),
                "mainDisplay": .bool(UserDefaults.standard.object(forKey: PhonePreferences.screenVirtualMainKey) as? Bool ?? true),
            ]
            if wanted == .virtual {
                await waitForViewSize()
                start["virtual"] = virtualSizeValue()
            }
            send(start)
            await receive(from: task)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func disconnect() {
        phase = .connecting
        resetUnlockState()
        guard let task else { return }
        send(["t": "stop"])
        task.cancel(with: .goingAway, reason: nil)
        self.task = nil
        format = nil
        audio.stop()
        layer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    }

    private func receive(from task: URLSessionWebSocketTask) async {
        while self.task === task {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                guard self.task === task else { return }
                self.task = nil
                resetUnlockState()
                phase = .failed(closeReason(task) ?? String(localized: "The connection to the computer dropped."))
                return
            }
            guard self.task === task else { return }
            switch message {
            case .data(let data): handleBinary(data)
            case .string(let text): handleText(text)
            @unknown default: break
            }
        }
    }

    private func closeReason(_ task: URLSessionWebSocketTask) -> String? {
        if let response = task.response as? HTTPURLResponse, response.statusCode == 501 {
            return String(localized: "This computer's Helm can't share its screen.")
        }
        if let response = task.response as? HTTPURLResponse, response.statusCode == 403 {
            return String(localized: "This phone isn't allowed to control the computer. Pair it again.")
        }
        return nil
    }

    func handleText(_ text: String) {
        guard let json = try? JSON.parse(Data(text.utf8)) else { return }
        switch json["t"]?.string {
        case "lockState":
            isLocked = json["locked"]?.bool ?? true
            lockStateAvailable = json["available"]?.bool == true
            unlockEnabled = json["unlockEnabled"]?.bool == true
            lockUser = json["user"]?.string
            if isLocked == false {
                if unlockInProgress { unlocked() }
                finishUnlock(message: nil)
            } else if !unlockEnabled, unlockInProgress {
                finishUnlock(message: String(localized: "Unlocking was turned off on the Mac."))
            }
        case "unlockResult":
            switch json["status"]?.string {
            case "submitted": break // Only a lockState change confirms that macOS accepted the password.
            case "unlocked":
                unlocked()
                finishUnlock(message: nil)
            case "notLocked": finishUnlock(message: nil)
            case "disabled": finishUnlock(message: String(localized: "Enable ‘Unlock Mac from your phone’ in Helm on the Mac under Settings → Connections."))
            case "focusPassword": finishUnlock(message: String(localized: "Select your user and click the password field on the Mac screen, then try again."))
            case "accessibility": finishUnlock(message: Self.accessibilityNotice)
            case "stillLocked":
                if usedSaved {
                    // Changed on the Mac since: type the new one, and the phone offers to keep it.
                    MacSecret.markStale(.mac, environmentId: environment.id)
                    finishUnlock(message: String(localized: "The saved password didn't work. Type the current one."))
                } else {
                    finishUnlock(message: String(localized: "The Mac is still locked. Check your password and try again."))
                }
            case "busy": finishUnlock(message: String(localized: "An unlock attempt is already in progress."))
            default: finishUnlock(message: String(localized: "The Mac couldn't accept the password. Try again."))
            }
        case "info":
            desktopSize = CGSize(width: json["width"]?.double ?? 0, height: json["height"]?.double ?? 0)
            phase = .live
            if json["accessibility"]?.bool == false { notice = Self.accessibilityNotice }
            if let id = json["display"]?.double {
                shown = .display(Int(id))
            } else if json["display"]?.string == "all" {
                shown = .all
            } else {
                shown = nil
                if wanted != .main {
                    notice = String(localized: "Update Helm on the computer to pick its displays or add one for this iPad.")
                }
            }
        case "cursorShape":
            guard let base64 = json["png"]?.string, let data = Data(base64Encoded: base64),
                  let image = UIImage(data: data) else { return }
            cursorShape = CursorShape(
                image: image,
                size: CGSize(width: json["width"]?.double ?? image.size.width, height: json["height"]?.double ?? image.size.height),
                hotSpot: CGPoint(x: json["hotX"]?.double ?? 0, y: json["hotY"]?.double ?? 0))
        case "clipboard":
            // The computer copied something: it's here to paste.
            if sharesClipboard, let text = json["text"]?.string { UIPasteboard.general.string = text }
        case "displays":
            displays = (json["displays"]?.array ?? []).compactMap { item in
                guard let id = item["id"]?.double else { return nil }
                return Display(id: Int(id), name: item["name"]?.string ?? "",
                               frame: CGRect(x: item["x"]?.double ?? 0, y: item["y"]?.double ?? 0,
                                             width: item["width"]?.double ?? 0, height: item["height"]?.double ?? 0),
                               isMain: item["main"]?.bool ?? false, isVirtual: item["virtual"]?.bool ?? false)
            }
        case "windows":
            windowIcons = (json["icons"]?.object ?? [:]).reduce(into: [:]) { icons, entry in
                if let pid = Int(entry.key), let base64 = entry.value.string,
                   let data = Data(base64Encoded: base64), let image = UIImage(data: data) { icons[pid] = image }
            }
            windows = (json["windows"]?.array ?? []).compactMap { item in
                guard let id = item["id"]?.double else { return nil }
                return RemoteWindow(id: Int(id), pid: Int(item["pid"]?.double ?? 0), app: item["app"]?.string ?? "",
                                    title: item["title"]?.string ?? "", display: Int(item["display"]?.double ?? 0))
            }
        case "windowMoved":
            // Moved where this iPad can see it.
            if let virtualDisplay, shown != .display(virtualDisplay.id) { show(.virtual) }
        case "cursor":
            guard Date().timeIntervalSince(movedLocallyAt) > 0.4 else { return }
            cursor = CGPoint(x: json["x"]?.double ?? 0, y: json["y"]?.double ?? 0)
        case "error":
            switch json["code"]?.string {
            case "accessibility": notice = Self.accessibilityNotice
            case "virtualDisplay":
                notice = String(localized: "The computer couldn't add a display for this iPad, so it shows its main one.")
            case "moveWindow":
                notice = String(localized: "The window couldn't be brought to this iPad.")
            case "screenRecording":
                phase = .failed(String(localized: "Allow Helm to record the screen on the computer: System Settings → Privacy & Security → Screen & System Audio Recording. Then try again."))
            default: phase = .failed(json["message"]?.string ?? String(localized: "The computer couldn't share its screen."))
            }
        default: break
        }
    }

    private static var accessibilityNotice: String {
        String(localized: "The computer won't take clicks and keys yet: allow Helm in System Settings → Privacy & Security → Accessibility.")
    }

    // MARK: Unlock

    /// Dedicated ephemeral command: no draft, preferences or clipboard. The password goes to the
    /// Keychain only if, after it worked, the person chooses to keep it for Face ID.
    func unlock(password: String) async {
        await unlock(password: password, saved: false)
    }

    /// Face ID, then the password saved for this Mac. False when there's none or Face ID was cancelled.
    @discardableResult
    func unlockWithFaceID() async -> Bool {
        guard canUnlockWithFaceID, !unlockInProgress else { return false }
        let reason = String(localized: "Unlock \(environment.label)")
        guard let password = try? await MacSecret.read(.mac, environmentId: environment.id, reason: reason) else { return false }
        await unlock(password: password, saved: true)
        return true
    }

    private func unlocked() {
        defer { typedPassword = nil }
        guard let typed = typedPassword, MacSecret.shouldOffer(.mac, environmentId: environment.id) else { return }
        saveOffer = PasswordSaveOffer(kind: .mac, environmentId: environment.id, password: typed)
    }

    private func unlock(password: String, saved: Bool) async {
        guard isLocked == true, lockStateAvailable, unlockEnabled, !unlockInProgress else { return }
        guard !password.isEmpty, password.utf16.count <= 1024,
              !password.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            unlockMessage = String(localized: "Enter a valid Mac password.")
            return
        }
        guard phase == .live, let socket = task else {
            unlockMessage = String(localized: "Reconnect to the Mac before unlocking it.")
            return
        }
        unlockInProgress = true
        unlockMessage = nil
        usedSaved = saved
        typedPassword = saved ? nil : password
        do {
            let data = try JSON.object(["t": "unlock", "password": .string(password)]).data()
            try await socket.send(.string(String(decoding: data, as: UTF8.self)))
            guard task === socket, unlockInProgress else { return }
            unlockTimeout?.cancel()
            unlockTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(12))
                guard !Task.isCancelled, let self, self.unlockInProgress else { return }
                self.finishUnlock(message: String(localized: "The Mac didn't confirm unlocking. Check the connection and try again."))
            }
        } catch {
            guard task === socket else { return }
            finishUnlock(message: String(localized: "The password couldn't be sent. Check the connection and try again."))
        }
    }

    private func finishUnlock(message: String?) {
        if message != nil { typedPassword = nil }
        unlockTimeout?.cancel()
        unlockTimeout = nil
        unlockInProgress = false
        unlockMessage = message
    }

    private func resetUnlockState() {
        typedPassword = nil
        finishUnlock(message: nil)
        isLocked = nil
        lockStateAvailable = false
        unlockEnabled = false
        lockUser = nil
    }

    // MARK: Displays

    /// Switches what the video shows; the computer answers with a new picture and size.
    func show(_ target: Shown) {
        wanted = target
        var command: [String: JSON] = ["t": "show", "display": displayValue(target)]
        if target == .virtual { command["virtual"] = virtualSizeValue() }
        send(command)
    }

    /// Asks the computer for its other displays' windows.
    func listWindows() {
        windows = nil
        send(["t": "windows"])
    }

    /// Moves a window onto this iPad's display; the computer puts it back when the display goes.
    func bringWindow(_ window: RemoteWindow) {
        send(["t": "moveWindow", "id": .number(Double(window.id))])
    }

    /// The screen here changed size (the iPad turned, or its window did): the separate display follows.
    func viewSizeChanged(_ size: CGSize) {
        guard size != viewSize else { return }
        viewSize = size
        guard virtualDisplay != nil, virtualSize != sentVirtualSize else { return }
        resizeTask?.cancel()
        resizeTask = Task { [weak self] in
            // Once the rotation settles.
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            var command: [String: JSON] = ["t": "virtualSize"]
            command.merge(virtualSizeValue().object ?? [:]) { $1 }
            send(command)
        }
    }

    private func displayValue(_ target: Shown) -> JSON {
        switch target {
        case .main: .string("main")
        case .display(let id): .number(Double(id))
        case .all: .string("all")
        case .virtual: .string("virtual")
        }
    }

    /// The separate display in points: this screen's size, scaled up for more room if asked.
    private var virtualSize: CGSize {
        let scale = UserDefaults.standard.string(forKey: PhonePreferences.screenVirtualSizeKey)
            .flatMap(ScreenVirtualSize.init(rawValue:))?.scale ?? 1
        return CGSize(width: (viewSize.width * scale).rounded(), height: (viewSize.height * scale).rounded())
    }

    private func virtualSizeValue() -> JSON {
        let size = virtualSize
        sentVirtualSize = size
        return .object(["width": .number(size.width), "height": .number(size.height)])
    }

    /// The view lays out a moment after the connection starts.
    private func waitForViewSize() async {
        for _ in 0..<20 where viewSize == .zero {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: Video

    /// [u8 kind][payload]: 2 is H.264's SPS and PPS, 4 HEVC's VPS, SPS and PPS (both
    /// `[count][u16 length + set]…`), 1 a frame (`[flags][u64 pts µs][length-prefixed NALs]`),
    /// 3 sound, 5 a keep-awake tick.
    private func handleBinary(_ data: Data) {
        guard let kind = data.first else { return }
        let payload = data.dropFirst()
        switch kind {
        case 2: format = Self.format(from: payload, hevc: false)
        case 4: format = Self.format(from: payload, hevc: true)
        case 1:
            guard payload.count > 9, let format, let sample = Self.sample(Data(payload.dropFirst(9)), format: format) else { return }
            let renderer = layer.sampleBufferRenderer
            if renderer.status == .failed {
                renderer.flush()
                send(["t": "keyframe"])
                return
            }
            renderer.enqueue(sample)
            if framesShown < 2 { framesShown += 1 }
        case 3: audio.play(Data(payload))
        default: break
        }
    }

    private static func format(from payload: Data.SubSequence, hevc: Bool) -> CMVideoFormatDescription? {
        var bytes = Array(payload)
        guard let count = bytes.first else { return nil }
        var sets: [[UInt8]] = []
        var index = 1
        for _ in 0..<count {
            guard index + 2 <= bytes.count else { return nil }
            let length = Int(bytes[index]) << 8 | Int(bytes[index + 1])
            index += 2
            guard index + length <= bytes.count else { return nil }
            sets.append(Array(bytes[index..<index + length]))
            index += length
        }
        bytes = []
        var format: CMVideoFormatDescription?
        let pointers = sets.map { set in
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            pointer.initialize(from: set, count: set.count)
            return UnsafePointer(pointer)
        }
        defer { pointers.forEach { UnsafeMutablePointer(mutating: $0).deallocate() } }
        let status = hevc
            ? CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: pointers,
                parameterSetSizes: sets.map(\.count), nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &format)
            : CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: pointers,
                parameterSetSizes: sets.map(\.count), nalUnitHeaderLength: 4, formatDescriptionOut: &format)
        return status == noErr ? format : nil
    }

    private static func sample(_ data: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: data.count, flags: 0, blockBufferOut: &block) == noErr,
            let block else { return nil }
        let copied = data.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
                                          dataLength: data.count)
        }
        guard copied == noErr else { return nil }
        var sample: CMSampleBuffer?
        var size = data.count
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size,
            sampleBufferOut: &sample) == noErr, let sample else { return nil }
        // Live: each frame shows as soon as it's decoded, no clock.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }

    // MARK: Input

    /// Moves the cursor by `delta` of the computer's points (the trackpad), kept on the display.
    func moveCursor(by delta: CGPoint) {
        guard desktopSize != .zero else { return }
        cursor = CGPoint(x: min(max(0, cursor.x + delta.x), desktopSize.width - 1),
                         y: min(max(0, cursor.y + delta.y), desktopSize.height - 1))
        movedLocallyAt = Date()
        send(["t": "move", "x": .number(cursor.x), "y": .number(cursor.y)])
    }

    func click(_ button: Button = .left) {
        press(button, down: true)
        press(button, down: false)
    }

    /// Holds or lets go of a button at the cursor (a drag holds the left one while moving).
    func press(_ button: Button = .left, down: Bool) {
        buttonHeld = down
        send(["t": "button", "b": .string(button.rawValue), "down": .bool(down),
              "x": .number(cursor.x), "y": .number(cursor.y)])
    }

    /// A trackpad scroll's stage: the fingers' (began, changed, ended), then the glide the phone
    /// works out after they lift, which the computer shows as a real trackpad's momentum.
    enum ScrollPhase: String {
        case began, changed, ended, momentumBegan, momentum, momentumEnded
    }

    /// Scrolls the computer by `dx`, `dy` pixels (positive `dy` moves the content down).
    func scroll(dx: CGFloat, dy: CGFloat, phase: ScrollPhase? = nil) {
        var command: [String: JSON] = ["t": "scroll", "dx": .number(dx), "dy": .number(dy)]
        if let phase { command["phase"] = .string(phase.rawValue) }
        send(command)
    }

    /// Moves the cursor to a point on the computer's screen (touch mode, a pointer, a pencil).
    func moveCursor(to point: CGPoint) {
        guard desktopSize != .zero else { return }
        cursor = CGPoint(x: min(max(0, point.x), desktopSize.width - 1), y: min(max(0, point.y), desktopSize.height - 1))
        movedLocallyAt = Date()
        send(["t": "move", "x": .number(cursor.x), "y": .number(cursor.y)])
    }

    /// This device's copied text onto the computer's clipboard, pasted at the cursor (⌘V).
    /// Reading it is what makes iOS ask once whether to allow pasting.
    func pasteFromDevice() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        // The server takes commands up to 64 KB; longer text is typed instead.
        guard text.utf8.count < 60_000 else {
            type(text)
            return
        }
        send(["t": "clipboard", "text": .string(text)])
        key(9, modifiers: [.cmd])
    }

    /// Typed text goes as Unicode, whatever the computer's keyboard layout.
    func type(_ text: String) {
        send(["t": "text", "s": .string(text)])
    }

    /// A key by its Mac virtual key code, with modifiers held for it.
    func key(_ code: Int, modifiers: Set<Modifier> = []) {
        send(["t": "key", "code": .number(Double(code)), "mods": .array(modifiers.map { .string($0.rawValue) })])
    }

    /// A modifier held on the Mac across keys until it's let go (⌘ through the app switcher).
    func modifier(_ modifier: Modifier, down: Bool) {
        send(["t": "modifier", "key": .string(modifier.rawValue), "down": .bool(down)])
    }

    private func send(_ command: [String: JSON]) {
        guard let task, let data = try? JSON.object(command).data() else { return }
        task.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
    }
}

/// Mac virtual key codes (ANSI layout) for what the phone's keyboard types, used when a modifier
/// is held (⌘C needs the key, not the letter).
enum MacKeyCode {
    static let returnKey = 36, tab = 48, space = 49, delete = 51, escape = 53
    static let left = 123, right = 124, down = 125, up = 126

    /// A hardware keyboard's key (HID usage, as `UIKey.keyCode` reports it) as the Mac's key code.
    static func code(forHID usage: UIKeyboardHIDUsage) -> Int? {
        let letters = [0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6]
        let digits = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]  // 1…9, 0
        let functions = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]  // F1…F12
        let raw = usage.rawValue
        switch raw {
        case 0x04...0x1D: return letters[raw - 0x04]
        case 0x1E...0x27: return digits[raw - 0x1E]
        case 0x3A...0x45: return functions[raw - 0x3A]
        default: break
        }
        let table: [UIKeyboardHIDUsage: Int] = [
            .keyboardReturnOrEnter: returnKey, .keyboardEscape: escape, .keyboardDeleteOrBackspace: delete,
            .keyboardTab: tab, .keyboardSpacebar: space, .keyboardHyphen: 27, .keyboardEqualSign: 24,
            .keyboardOpenBracket: 33, .keyboardCloseBracket: 30, .keyboardBackslash: 42, .keyboardSemicolon: 41,
            .keyboardQuote: 39, .keyboardGraveAccentAndTilde: 50, .keyboardComma: 43, .keyboardPeriod: 47,
            .keyboardSlash: 44, .keyboardRightArrow: right, .keyboardLeftArrow: left, .keyboardDownArrow: down,
            .keyboardUpArrow: up, .keyboardDeleteForward: 117, .keyboardHome: 115, .keyboardEnd: 119,
            .keyboardPageUp: 116, .keyboardPageDown: 121, .keypadEnter: 76,
        ]
        return table[usage]
    }

    static func code(for character: Character) -> Int? {
        let table: [Character: Int] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
            "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
            "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
            "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46,
            ".": 47, "`": 50, " ": space, "\n": returnKey, "\t": tab,
        ]
        return table[Character(character.lowercased())]
    }
}
