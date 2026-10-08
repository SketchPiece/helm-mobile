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
    /// Bumped each time a spoken message went out (drives the haptic).
    private(set) var sentCount = 0

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

    private func send(_ text: String) async {
        guard let session else { return }
        let followUp = FollowUpBehavior(
            rawValue: UserDefaults.standard.string(forKey: PhonePreferences.followUpKey) ?? ""
        ) ?? .queue
        await session.send(text: text, attachments: [], followUp: followUp.followUp,
                           modelSelection: nil, runtimeMode: nil, interactionMode: nil)
        if let failed = session.outbox.last(where: { $0.text == text })?.failed {
            sendError = failed
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        } else {
            sendError = nil
            sentCount += 1
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
