import Foundation
import Observation
import UIKit

/// The phone as a remote for the thread open in Helm on a Mac nearby: talk into it (the words
/// are sent as a message), stop the run, answer what the agent asks. Home's pill and the remote
/// sheet share one of these.
@MainActor
@Observable
final class MacRemote {
    let voice = VoiceInput()
    private(set) var target: MacRemoteTarget?
    /// The open thread's live subscription, held while the remote is offered.
    private(set) var session: ThreadSession?
    private(set) var environment: EnvironmentSession?
    /// Why the last message didn't go, until the next one does.
    private(set) var sendError: String?
    /// Bumped each time a message went out (drives the haptic).
    private(set) var sentCount = 0
    /// A screenshot that goes out with the next thing said.
    var pendingScreenshot: UIImage?
    /// A message with a screenshot is on its way up.
    private(set) var isSending = false

    /// A thread just picked on the phone, kept while the Mac catches up: its next report may
    /// still name the thread it showed before.
    @ObservationIgnored private var switching: (threadId: String, until: Date)?

    /// Points the remote at `target` (nil: nothing to offer), keeping the thread subscribed.
    func follow(_ target: MacRemoteTarget?, in model: AppModel) {
        if let switching, Date() < switching.until, target?.ref.threadId != switching.threadId { return }
        switching = nil
        guard target != self.target else { return }
        // Mid-sentence the Mac may switch threads or doze off; the take still goes where it began.
        // The views follow again once the voice is idle.
        if voice.isRecording || voice.state == .transcribing { return }
        point(at: target, in: model)
    }

    private func point(at target: MacRemoteTarget?, in model: AppModel) {
        self.target = target
        sendError = nil
        guard let target, let environment = model.environment(target.ref.environmentId) else {
            session = nil
            environment = nil
            return
        }
        self.environment = environment
        session = environment.threadSession(target.ref.threadId)
        voice.warmUp()
    }

    var thread: ThreadSummary? {
        guard let target else { return nil }
        return environment?.thread(target.ref.threadId)
    }

    var isWorking: Bool { session?.projection?.isWorking ?? thread?.isWorking ?? false }

    // MARK: Other threads on this computer

    /// This computer's threads in Home's order: what needs you, then pinned and active ones.
    func threads(in model: AppModel) -> (waiting: [ThreadListEntry], others: [ThreadListEntry]) {
        guard let environmentId = target?.ref.environmentId else { return ([], []) }
        let sections = HomeSections(entries: model.allThreads().filter { $0.ref.environmentId == environmentId })
        return (sections.attention, sections.pinned + sections.active)
    }

    /// The thread the remote moves on to after Settle or Snooze: the next one that needs you.
    func nextWaiting(in model: AppModel) -> ThreadListEntry? {
        threads(in: model).waiting.first { $0.ref != target?.ref }
    }

    /// Opens `ref` on the computer without bringing Helm forward, and follows it here at once.
    func switchTo(_ ref: ThreadRef, in model: AppModel) async {
        guard let target, ref != target.ref, !voice.isRecording, voice.state != .transcribing,
              let environment = model.environment(ref.environmentId)
        else { return }
        switching = (ref.threadId, Date().addingTimeInterval(4))
        point(at: MacRemoteTarget(ref: ref, macLabel: target.macLabel), in: model)
        UISelectionFeedbackGenerator().selectionChanged()
        do {
            let opened = try await environment.sendRemoteCommand([
                "type": "thread.open", "threadId": .string(ref.threadId), "reveal": false,
            ])
            if !opened { sendError = String(localized: "Helm on the computer didn't switch threads.") }
        } catch {
            sendError = error.localizedDescription
        }
    }

    /// The thread before or after this one in Home's order (`step` −1 or 1), for the swipe.
    func neighbour(_ step: Int, in model: AppModel) -> ThreadRef? {
        let lists = threads(in: model)
        let all = (lists.waiting + lists.others).map(\.ref)
        guard let index = all.firstIndex(where: { $0 == target?.ref }) else { return all.first }
        let next = index + step
        return all.indices.contains(next) ? all[next] : nil
    }

    /// Settles or snoozes the thread on the computer, then moves on to the next one that needs you.
    func settle(_ action: AppModel.ThreadAction, in model: AppModel) async {
        guard let ref = target?.ref else { return }
        let next = nextWaiting(in: model)
        do {
            try await model.perform(action, on: ref)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            if case .unsettle = action { return }
            if let next { await switchTo(next.ref, in: model) }
        } catch {
            sendError = error.localizedDescription
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    /// Stops the recording and sends what was said to the thread.
    func finishAndSend() async {
        guard let environment, let session else {
            voice.cancel()
            return
        }
        guard let text = await voice.finish(environment: environment, threadId: session.threadId) else { return }
        await send(text)
    }

    func retryTranscription() async {
        guard let environment, let session,
              let text = await voice.retry(environment: environment, threadId: session.threadId)
        else { return }
        await send(text)
    }

    /// Sends a screenshot on its own, right away.
    func sendScreenshot(_ image: UIImage) async {
        pendingScreenshot = image
        await send("")
    }

    private func send(_ text: String) async {
        guard let session, let environment else { return }
        if voiceTarget == .composer, !text.isEmpty, pendingScreenshot == nil {
            await type(text, threadId: session.threadId, in: environment)
            return
        }
        isSending = true
        defer { isSending = false }
        var attachments: [ChatAttachment] = []
        if let screenshot = pendingScreenshot {
            do {
                attachments.append(try await environment.uploadImage(screenshot, name: "screenshot.jpg"))
                pendingScreenshot = nil
            } catch {
                sendError = error.localizedDescription
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                return
            }
        }
        let followUp = FollowUpBehavior(
            rawValue: UserDefaults.standard.string(forKey: PhonePreferences.followUpKey) ?? ""
        ) ?? .queue
        await session.send(text: text, attachments: attachments, followUp: followUp.followUp,
                           modelSelection: nil, runtimeMode: nil, interactionMode: nil)
        if let failed = session.outbox.last?.failed {
            sendError = failed
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        } else {
            sendError = nil
            sentCount += 1
        }
    }

    /// Where the words go: sent as a message (the default), or typed into the computer's composer.
    enum VoiceTarget: String, CaseIterable {
        case send, composer
        static let key = "macRemoteVoiceTarget"
    }

    var voiceTarget: VoiceTarget {
        get {
            access(keyPath: \.voiceTarget)
            return VoiceTarget(rawValue: UserDefaults.standard.string(forKey: VoiceTarget.key) ?? "") ?? .send
        }
        set {
            withMutation(keyPath: \.voiceTarget) { UserDefaults.standard.set(newValue.rawValue, forKey: VoiceTarget.key) }
        }
    }

    /// Puts the words at the end of the thread's draft on the computer, to edit and send there.
    private func type(_ text: String, threadId: String, in environment: EnvironmentSession) async {
        do {
            let delivered = try await environment.sendRemoteCommand([
                "type": "composer.insert", "threadId": .string(threadId), "text": .string(text),
            ])
            if delivered {
                sendError = nil
                sentCount += 1
            } else {
                sendError = String(localized: "Helm on the computer didn't take it. Update Helm there, or send instead.")
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        } catch {
            sendError = error.localizedDescription
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    func stop() async {
        do {
            try await session?.interrupt()
        } catch {
            sendError = error.localizedDescription
        }
    }
}
