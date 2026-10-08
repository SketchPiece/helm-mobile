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

    /// Points the remote at `target` (nil: nothing to offer), keeping the thread subscribed.
    func follow(_ target: MacRemoteTarget?, in model: AppModel) {
        guard target != self.target else { return }
        // Mid-sentence the Mac may switch threads or doze off; the take still goes where it began.
        // The views follow again once the voice is idle.
        if voice.isRecording || voice.state == .transcribing { return }
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
