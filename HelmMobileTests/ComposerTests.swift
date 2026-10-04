import XCTest
@testable import HelmMobile

final class ComposerTriggerTests: XCTestCase {
    private func detect(_ text: String) -> ComposerTrigger? { ComposerTrigger.detect(in: text) }

    func testSlashOnlyAtLineStartWithoutSpace() {
        XCTAssertEqual(detect("/rev"), ComposerTrigger(kind: .slashCommand, query: "rev", rangeStart: 0, rangeEnd: 4))
        XCTAssertEqual(detect("first line\n/pl"), ComposerTrigger(kind: .slashCommand, query: "pl", rangeStart: 11, rangeEnd: 14))
        XCTAssertNil(detect("/review now"))
        XCTAssertNil(detect("see /tmp"))
    }

    func testSlashModel() {
        XCTAssertEqual(detect("/Model")?.kind, .slashModel)
        XCTAssertEqual(detect("/model gpt 6")?.query, "gpt 6")
    }

    func testTrailingTokenKinds() {
        XCTAssertEqual(detect("look at @src/co"), ComposerTrigger(kind: .path, query: "src/co", rangeStart: 8, rangeEnd: 15))
        XCTAssertEqual(detect("use $front"), ComposerTrigger(kind: .skill, query: "front", rangeStart: 4, rangeEnd: 10))
        XCTAssertEqual(detect("€x")?.kind, .skill)
        XCTAssertEqual(detect("fixes #12"), ComposerTrigger(kind: .pullRequest, query: "12", rangeStart: 6, rangeEnd: 9))
        XCTAssertEqual(detect("#")?.query, "")
        XCTAssertNil(detect("# heading"))
        XCTAssertNil(detect("issue#1"))
        XCTAssertNil(detect("@done "))
        XCTAssertNil(detect("plain words"))
    }

    func testOffsetsAreUTF16() {
        // The emoji is two UTF-16 units, as in the TypeScript original.
        XCTAssertEqual(detect("😀 @a")?.rangeStart, 3)
        let trigger = detect("😀 @a")!
        XCTAssertEqual(trigger.replacing(in: "😀 @a", with: "x"), "😀 x")
    }

    func testPickReplacesOnlyTheToken() {
        let text = "look at @src/co"
        let trigger = detect(text)!
        XCTAssertEqual(trigger.replacing(in: text, with: ComposerTrigger.fileLink("src/components/Button.tsx") + " "),
                       "look at [Button.tsx](src/components/Button.tsx) ")
        XCTAssertEqual(detect("/pl")!.replacing(in: "/pl", with: ""), "")
    }

    func testFileLinkEscaping() {
        XCTAssertEqual(ComposerTrigger.fileLink("docs/a (b)#c?.md"), "[a (b)#c?.md](docs/a%20%28b%29%23c%3F.md)")
        XCTAssertEqual(ComposerTrigger.fileLink("x/[w].md"), "[\\[w\\].md](x/%5Bw%5D.md)")
        XCTAssertEqual(ComposerTrigger.fileLink("100%.txt"), "[100%.txt](100%25.txt)")
    }
}

final class PastedTextTests: XCTestCase {
    func testThreshold() {
        let limit = AttachmentLimits.pastedTextThreshold
        XCTAssertFalse(PastedText.shouldAttach(String(repeating: "a", count: limit - 1), draftLength: 0, canAttach: true))
        XCTAssertTrue(PastedText.shouldAttach(String(repeating: "a", count: limit), draftLength: 0, canAttach: true))
        // Half as many Cyrillic letters reach the same byte count.
        XCTAssertTrue(PastedText.shouldAttach(String(repeating: "ж", count: limit / 2), draftLength: 0, canAttach: true))
        // A short paste that would push the draft past the message limit.
        XCTAssertTrue(PastedText.shouldAttach("twenty characters...", draftLength: 119_990, canAttach: true))
        XCTAssertFalse(PastedText.shouldAttach(String(repeating: "a", count: limit), draftLength: 0, canAttach: false))
    }

    func testFileNames() {
        XCTAssertEqual(PastedText.nextFileName(existing: []), "pasted-text.txt")
        XCTAssertEqual(PastedText.nextFileName(existing: ["Pasted-Text.txt", "photo.jpg"]), "pasted-text-2.txt")
        XCTAssertEqual(PastedText.nextFileName(existing: ["pasted-text.txt", "pasted-text-2.txt"]), "pasted-text-3.txt")
    }

    func testInsertionFindsThePastedChunk() {
        let (range, inserted) = PastedText.insertion(from: "ab", to: "aXYZb")
        XCTAssertEqual(range, NSRange(location: 1, length: 3))
        XCTAssertEqual(inserted, "XYZ")
        XCTAssertEqual(PastedText.insertion(from: "", to: "pasted").inserted, "pasted")
        XCTAssertEqual(PastedText.insertion(from: "aa", to: "aaa").inserted, "a")
    }

    func testImagePromotion() {
        XCTAssertEqual(AttachmentLimits.imageMimeType(name: "a.PNG", mimeType: "application/octet-stream"), "image/png")
        XCTAssertEqual(AttachmentLimits.imageMimeType(name: "a.webp", mimeType: ""), "image/webp")
        XCTAssertEqual(AttachmentLimits.imageMimeType(name: "scan", mimeType: "image/jpeg; q=1"), "image/jpeg")
        XCTAssertNil(AttachmentLimits.imageMimeType(name: "a.png", mimeType: "application/pdf"))
        XCTAssertNil(AttachmentLimits.imageMimeType(name: "x.heic", mimeType: "image/heic"))
        XCTAssertNil(AttachmentLimits.imageMimeType(name: "notes.txt", mimeType: "text/plain"))
    }
}

final class ComposerMessageTests: XCTestCase {
    private let file = ChatAttachment(id: "att_1", type: "file", name: "build.log", mimeType: "text/plain", sizeBytes: 18233)
    private let paste = ChatAttachment(id: "att_2", type: "file", name: "pasted-text.txt", mimeType: PastedText.mimeType,
                                       sizeBytes: 40000, source: "pasted-text")
    private let image = ChatAttachment(id: "att_3", type: "image", name: "photo.jpg", mimeType: "image/jpeg", sizeBytes: 900)
    private var pullRequest: PullRequestReference {
        PullRequestReference(json: [
            "number": 42, "title": "Fix login", "url": "https://github.com/acme/app/pull/42", "headBranch": "fix-login",
            "baseBranch": "main", "state": "open", "isDraft": false,
        ], contextId: "pr-ctx")!
    }

    func testFilesAppendLinksInOrderAndRecords() {
        let message = ComposerMessage.build(
            text: "Why does this fail?",
            attachments: [("ctx-1", file), ("ctx-3", image), ("ctx-2", paste)], pullRequests: [], inlineContext: true
        )
        XCTAssertEqual(message.text, "Why does this fail? [build.log](t3-context://v1/file/ctx-1) [pasted-text.txt](t3-context://v1/file/ctx-2)")
        XCTAssertEqual(message.attachments.map(\.id), ["att_1", "att_3", "att_2"])
        let records = message.context?["records"]?.array ?? []
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0], [
            "version": 1, "kind": "file", "contextId": "ctx-1", "label": "build.log", "attachmentId": "att_1",
            "name": "build.log", "mimeType": "text/plain", "sizeBytes": 18233,
        ])
        XCTAssertEqual(message.context?["version"], 1)
        XCTAssertEqual(message.attachments[2].json["source"], ["_tag": "pasted-text"])
    }

    func testFilesOnlyMessageIsJustTheLinks() {
        let message = ComposerMessage.build(text: "", attachments: [("c", file)], pullRequests: [], inlineContext: true)
        XCTAssertEqual(message.text, "[build.log](t3-context://v1/file/c)")
    }

    func testPullRequestTokenBecomesLinkOnlyWhenStillInText() {
        let kept = ComposerMessage.build(text: "see #420 and #42 please", attachments: [], pullRequests: [pullRequest], inlineContext: true)
        XCTAssertEqual(kept.text, "see #420 and [#42](t3-context://v1/review-comment/pr-ctx) please")
        let record = kept.context?["records"]?[0]
        XCTAssertEqual(record?["kind"], "review-comment")
        XCTAssertEqual(record?["label"], "#42")
        XCTAssertEqual(record?["sectionId"], "pull-request:42")
        XCTAssertEqual(record?["text"]?.string?.hasPrefix("The pull request is #42, titled `Fix login`"), true)
        XCTAssertEqual(record?["pullRequest"]?["headBranch"], "fix-login")

        let removed = ComposerMessage.build(text: "never mind", attachments: [], pullRequests: [pullRequest], inlineContext: true)
        XCTAssertEqual(removed.text, "never mind")
        XCTAssertNil(removed.context)
    }

    func testLegacyServerGetsPlainTextAndBareList() {
        let message = ComposerMessage.build(text: "see #42", attachments: [("c", file)], pullRequests: [pullRequest], inlineContext: false)
        XCTAssertEqual(message.text, "see #42")
        XCTAssertNil(message.context)
        XCTAssertEqual(message.attachments.map(\.id), ["att_1"])
    }

    func testDisplayTextShowsLabels() {
        let text = "see [build.log](t3-context://v1/file/abc), [Button.tsx](src/components/Button.tsx) and [docs](https://x.dev/a)"
        XCTAssertEqual(ContextReference.displayText(text), "see build.log, Button.tsx and [docs](https://x.dev/a)")
        XCTAssertEqual(ContextReference.displayText("no links"), "no links")
    }

    func testLabelSanitising() {
        XCTAssertEqual(ContextReference.label("a [b]\nc", kind: "file"), "a b c")
        XCTAssertEqual(ContextReference.label("  ", kind: "file"), "file")
    }

    private let mention = ThreadReference(environmentId: "env-1", threadId: "t-9", title: "Fix [login]\nflow")

    func testThreadMentionBecomesThreadRecordAndLink() {
        XCTAssertEqual(mention.token, "@Fix login flow")
        let message = ComposerMessage.build(text: "like in @Fix login flow, and again @Fix login flow", attachments: [],
                                            pullRequests: [], threads: [mention, mention], inlineContext: true)
        let link = "[Fix login flow](t3-context://v1/thread/thread_t-9)"
        XCTAssertEqual(message.text, "like in \(link), and again \(link)")
        // One record per thread, the same shape as RN's threadComposerContext.
        XCTAssertEqual(message.context?["records"]?.array, [[
            "version": 1, "kind": "thread", "contextId": "thread_t-9", "label": "Fix login flow",
            "environmentId": "env-1", "threadId": "t-9", "title": "Fix login flow",
        ]])
        XCTAssertEqual(ContextReference.displayText(message.text), "like in Fix login flow, and again Fix login flow")
    }

    func testThreadMentionNeedsToStandAlone() {
        // Deleted from the text, glued to a word, or continued by one: no record.
        for text in ["never mind", "x@Fix login flow", "@Fix login flows"] {
            let message = ComposerMessage.build(text: text, attachments: [], pullRequests: [], threads: [mention], inlineContext: true)
            XCTAssertEqual(message.text, text)
            XCTAssertNil(message.context)
        }
        let legacy = ComposerMessage.build(text: "@Fix login flow", attachments: [], pullRequests: [], threads: [mention],
                                           inlineContext: false)
        XCTAssertEqual(legacy.text, "@Fix login flow")
        XCTAssertNil(legacy.context)
    }
}

final class QueuedEditTests: XCTestCase {
    private let log = ChatAttachment(id: "att_log", type: "file", name: "build.log", mimeType: "text/plain", sizeBytes: 10)
    private let photo = ChatAttachment(id: "att_img", type: "image", name: "photo.jpg", mimeType: "image/jpeg", sizeBytes: 900)
    private let notes = ChatAttachment(id: "att_new", type: "file", name: "notes.md", mimeType: "text/markdown", sizeBytes: 5)

    private var queued: QueuedMessage {
        QueuedMessage(
            id: "run-1", text: "Check this see [Old](t3-context://v1/thread/thread_t1) [build.log](t3-context://v1/file/c-log)",
            held: false, attachments: [log, photo],
            context: ["version": 1, "records": [
                ["version": 1, "kind": "thread", "contextId": "thread_t1", "label": "Old", "environmentId": "e",
                 "threadId": "t1", "title": "Old"],
                ["version": 1, "kind": "file", "contextId": "c-log", "label": "build.log", "attachmentId": "att_log",
                 "name": "build.log", "mimeType": "text/plain", "sizeBytes": 10],
            ]]
        )
    }

    func testEditorHidesTrailingFileLinksOnly() {
        let split = QueuedEdit.split(queued.text)
        XCTAssertEqual(split.body, "Check this see [Old](t3-context://v1/thread/thread_t1)")
        XCTAssertEqual(split.trailing.map(\.contextId), ["c-log"])
    }

    func testTextOnlyEditKeepsAttachmentsAndContext() {
        let split = QueuedEdit.split(queued.text)
        let payload = QueuedEdit.payload(body: "Now check this", trailing: split.trailing, original: queued,
                                         kept: [log, photo], added: [], inlineContext: true)
        XCTAssertEqual(payload, QueuedEdit.Payload(text: "Now check this [build.log](t3-context://v1/file/c-log)",
                                                   attachments: nil, context: nil))
    }

    func testRemovingAndAddingAttachmentsReplacesTheListAndRecords() {
        let split = QueuedEdit.split(queued.text)
        let payload = QueuedEdit.payload(body: split.body, trailing: split.trailing, original: queued,
                                         kept: [photo], added: [("c-new", notes)], inlineContext: true)
        XCTAssertEqual(payload.text, "Check this see [Old](t3-context://v1/thread/thread_t1) [notes.md](t3-context://v1/file/c-new)")
        XCTAssertEqual(payload.attachments?.map(\.id), ["att_img", "att_new"])
        let records = payload.context?["records"]?.array ?? []
        XCTAssertEqual(records.compactMap { $0["contextId"]?.string }, ["thread_t1", "c-new"])
        XCTAssertEqual(records.last?["attachmentId"], "att_new")
    }

    func testRemovingTheOnlyRecordedFileClearsItsRecord() {
        let message = QueuedMessage(id: "run-2", text: "Read [build.log](t3-context://v1/file/c-log) first", held: false,
                                    attachments: [log], context: ["version": 1, "records": [
                                        ["kind": "file", "contextId": "c-log", "attachmentId": "att_log"],
                                    ]])
        let split = QueuedEdit.split(message.text)
        XCTAssertTrue(split.trailing.isEmpty)
        let payload = QueuedEdit.payload(body: split.body, trailing: split.trailing, original: message, kept: [],
                                         added: [], inlineContext: true)
        XCTAssertEqual(payload.text, "Read first")
        XCTAssertEqual(payload.attachments, [])
        // Sent empty: leaving `context` out would keep the stale record.
        XCTAssertEqual(payload.context, ["version": 1, "records": []])
    }
}

final class ComposerSuggestionTests: XCTestCase {
    private func provider(_ json: JSON) -> Provider { Provider(json: json)! }

    private let flags = ComposerSuggestions.Flags(cwd: "/repo", hasThread: true, hasConversation: false, canChangeInteractionMode: true)

    private var claude: Provider {
        provider([
            "instanceId": "claudeAgent", "driver": "claudeAgent", "showInteractionModeToggle": true,
            "slashCommands": [["name": "review", "description": "Review changes"], ["name": "compact"],
                              ["name": "usage-limits"], ["name": "frontend-design"]],
            "skills": [["name": "frontend-design", "enabled": true, "path": "/s"],
                       ["name": "secret", "enabled": true, "userInvocable": false, "path": "/s"]],
        ])
    }

    func testSlashMenuAtMessageStart() {
        let items = ComposerSuggestions.slashItems(query: "", atMessageStart: true, provider: claude, scope: flags)
        XCTAssertEqual(items.map(\.title), ["/model", "/plan", "/default", "/review", "skill:frontend-design"])
        XCTAssertEqual(items[1].action, .interactionMode("plan"))
        XCTAssertEqual(items[3].action, .insert("/review "))
        XCTAssertEqual(items[4].action, .insert("$frontend-design "))
    }

    func testSlashMenuFiltersAndGates() {
        XCTAssertEqual(ComposerSuggestions.slashItems(query: "rev", atMessageStart: true, provider: claude, scope: flags).map(\.title),
                       ["/review"])
        // Provider commands only at the start of the message; built-ins anywhere.
        XCTAssertEqual(ComposerSuggestions.slashItems(query: "", atMessageStart: false, provider: claude, scope: flags).map(\.title),
                       ["/model", "/plan", "/default", "skill:frontend-design"])
        var withConversation = flags
        withConversation.hasConversation = true
        XCTAssertTrue(ComposerSuggestions.slashItems(query: "comp", atMessageStart: true, provider: claude, scope: withConversation)
            .contains { $0.title == "/compact" })
        let noModes = provider(["instanceId": "grok", "showInteractionModeToggle": false])
        XCTAssertEqual(ComposerSuggestions.slashItems(query: "", atMessageStart: true, provider: noModes, scope: flags).map(\.title),
                       ["/model"])
    }

    func testWorkspaceSnapshotOverridesGlobalLists() {
        let snapshot = provider([
            "instanceId": "claudeAgent", "showInteractionModeToggle": false, "slashCommands": [["name": "global"]],
            "workspaceSnapshots": [["cwd": "/repo", "slashCommands": [["name": "local"]], "skills": []]],
        ])
        XCTAssertEqual(ComposerSuggestions.slashItems(query: "", atMessageStart: true, provider: snapshot, scope: flags).map(\.title),
                       ["/model", "/local"])
        XCTAssertTrue(snapshot.hasSnapshot(cwd: "/repo"))
        XCTAssertFalse(snapshot.hasSnapshot(cwd: "/elsewhere"))
    }

    func testSkillRanking() {
        let skills = [
            ProviderSkill(name: "frontend-design"),
            ProviderSkill(name: "pdf", description: "Reads design docs"),
            ProviderSkill(name: "design-review", displayName: "Design Review"),
            ProviderSkill(json: ["name": "designer", "enabled": false])!,
            ProviderSkill(json: ["name": "design-bot", "userInvocable": false])!,
        ]
        let items = ComposerSuggestions.skillItems(query: "design", skills: skills)
        XCTAssertEqual(items.map(\.action), [.insert("$design-review "), .insert("$frontend-design "), .insert("$pdf ")])
        XCTAssertEqual(ComposerSuggestions.skillItems(query: "", skills: skills).count, 3)
    }

    func testThreadMatchesUnderAt() {
        let threads = [
            ("t1", "Fix login", "2026-10-01T11:00:00.000Z"), ("t2", "Login page polish", "2026-10-02T11:00:00.000Z"),
            ("t3", "Unrelated", "2026-10-03T11:00:00.000Z"), ("t4", "login again", "2026-09-01T11:00:00.000Z"),
        ].compactMap { ThreadSummary(json: Fixtures.thread(id: $0.0, extra: ["title": .string($0.1), "updatedAt": .string($0.2)])) }
        let items = ComposerSuggestions.threadItems(query: " LOGIN ", threads: threads, environmentId: "env", excluding: "t4")
        // Title contains the query, the composer's own thread left out, newest first.
        XCTAssertEqual(items.map(\.title), ["Login page polish", "Fix login"])
        XCTAssertEqual(items.first?.id, "thread:env:t2")
        XCTAssertEqual(items.first?.action, .thread(ThreadReference(environmentId: "env", threadId: "t2", title: "Login page polish")))
        // A bare `@` stays a file picker.
        XCTAssertTrue(ComposerSuggestions.threadItems(query: "", threads: threads, environmentId: "env", excluding: nil).isEmpty)
        let many = (0..<8).compactMap { ThreadSummary(json: Fixtures.thread(id: "m\($0)", extra: ["title": "same"])) }
        XCTAssertEqual(ComposerSuggestions.threadItems(query: "same", threads: many, environmentId: "env", excluding: nil).count, 5)
    }

    func testPullRequestMatches() {
        func entry(_ number: Int, _ title: String, updated: String, repository: String = "acme/app") -> JSON {
            ["projectId": "p1", "repository": .string(repository), "number": .number(Double(number)), "title": .string(title),
             "headBranch": "feature", "baseBranch": "main", "url": "u", "state": "open", "isDraft": false,
             "updatedAt": .string(updated)]
        }
        let entries = [
            entry(4, "Old one", updated: "2026-01-01T00:00:00Z"),
            entry(42, "Fix login", updated: "2026-03-01T00:00:00Z"),
            entry(14, "Login page", updated: "2026-02-01T00:00:00Z"),
            entry(4, "Elsewhere", updated: "2026-04-01T00:00:00Z", repository: "acme/other"),
            entry(42, "Duplicate", updated: "2026-03-01T00:00:00Z"),
        ]
        XCTAssertEqual(ComposerSuggestions.pullRequestMatches(entries, query: "4", projectId: "p1", repository: "Acme/App").map(\.number),
                       [4, 42, 14])
        XCTAssertEqual(ComposerSuggestions.pullRequestMatches(entries, query: "login fix", projectId: "p1", repository: "acme/app")
            .map(\.number), [42])
        XCTAssertEqual(ComposerSuggestions.pullRequestMatches(entries, query: "", projectId: "p1", repository: "acme/app").map(\.number),
                       [42, 14, 4])
    }
}
