import XCTest
@testable import HelmMobile

final class FolderPathTests: XCTestCase {
    func testBreadcrumbsCollapseHome() {
        let crumbs = FolderPath.breadcrumbs("/Users/me/Projects/app")
        XCTAssertEqual(crumbs.map(\.name), ["~", "Projects", "app"])
        XCTAssertEqual(crumbs.map(\.path), ["/Users/me", "/Users/me/Projects", "/Users/me/Projects/app"])
    }

    func testBreadcrumbsOutsideHomeStartAtRoot() {
        let crumbs = FolderPath.breadcrumbs("/tmp/helm-sandbox/")
        XCTAssertEqual(crumbs.map(\.name), ["/", "tmp", "helm-sandbox"])
        XCTAssertEqual(crumbs.map(\.path), ["/", "/tmp", "/tmp/helm-sandbox"])
        XCTAssertEqual(FolderPath.breadcrumbs("/").map(\.path), ["/"])
        XCTAssertEqual(FolderPath.breadcrumbs("/home/me").map(\.name), ["~"])
    }

    func testShortJoinAndTitle() {
        XCTAssertEqual(FolderPath.short("/Users/me/T3 Projects"), "~/T3 Projects")
        XCTAssertEqual(FolderPath.short("/opt/x"), "/opt/x")
        XCTAssertEqual(FolderPath.join("~", "repo"), "~/repo")
        XCTAssertEqual(FolderPath.join("/Users/me/", "repo"), "/Users/me/repo")
        XCTAssertEqual(FolderPath.lastSegment("/Users/me/my-app/"), "my-app")
        XCTAssertEqual(FolderPath.directoryQuery("~"), "~/")
    }

    func testCreateCommandUsesFolderNameAsTitle() {
        let command = ProjectCommands.create(projectId: "p1", path: "/tmp/helm-test/my-app")
        XCTAssertEqual(command["type"]?.string, "project.create")
        XCTAssertEqual(command["title"]?.string, "my-app")
        XCTAssertEqual(command["createWorkspaceRootIfMissing"]?.bool, true)
        XCTAssertEqual(command["defaultModelSelection"]?.isNull, true)
    }
}

final class CloneSourceTests: XCTestCase {
    func testGitHubShorthandBecomesHTTPSURL() {
        let source = CloneSource("  acme/rocket ")
        XCTAssertEqual(source?.shorthand, "acme/rocket")
        XCTAssertEqual(source?.remoteUrl, "https://github.com/acme/rocket.git")
        XCTAssertEqual(source?.directoryName, "rocket")
        XCTAssertEqual(CloneSource("acme/rocket.git")?.shorthand, "acme/rocket")
    }

    func testPastedURLsKeepTheirForm() {
        let https = CloneSource("https://gitlab.com/group/sub/tool.git")
        XCTAssertNil(https?.shorthand)
        XCTAssertEqual(https?.remoteUrl, "https://gitlab.com/group/sub/tool.git")
        XCTAssertEqual(https?.directoryName, "tool")
        XCTAssertEqual(CloneSource("git@github.com:acme/rocket.git")?.directoryName, "rocket")
        XCTAssertEqual(CloneSource("ssh://git@host:22/acme/repo")?.directoryName, "repo")
        XCTAssertEqual(CloneSource("https://host/acme/123/")?.directoryName, "123")
        XCTAssertEqual(CloneSource("https://github.com/acme/rocket?tab=readme")?.directoryName, "rocket")
    }

    func testInputsWithoutARepositoryAreRejected() {
        XCTAssertNil(CloneSource(""))
        XCTAssertNil(CloneSource("https://github.com"))
        XCTAssertNil(CloneSource("https://host:8080"))
    }

    func testRepositoryInfoCloneURLFollowsProvider() {
        let github = RepositoryInfo(json: ["provider": "github", "nameWithOwner": "a/b", "url": "https://github.com/a/b", "sshUrl": "git@github.com:a/b.git"])
        XCTAssertEqual(github?.cloneUrl, "https://github.com/a/b")
        let gitlab = RepositoryInfo(json: ["provider": "gitlab", "nameWithOwner": "a/b", "url": "https://gitlab.com/a/b", "sshUrl": "git@gitlab.com:a/b.git"])
        XCTAssertEqual(gitlab?.cloneUrl, "git@gitlab.com:a/b.git")
    }

    func testGitHubTargetFromDiscovery() {
        func discovery(status: String, auth: String, account: JSON) -> JSON {
            ["sourceControlProviders": [["kind": "github", "status": .string(status), "auth": ["status": .string(auth), "account": account]]]]
        }
        let ready = GitHubTarget(discovery: discovery(status: "available", auth: "authenticated", account: ["_tag": "Some", "value": "me"]))
        XCTAssertEqual(ready?.account, "me")
        XCTAssertEqual(ready?.repository(for: "/Users/me/T3 Projects/weather-bot"), "me/weather-bot")
        let anonymous = GitHubTarget(discovery: discovery(status: "available", auth: "unknown", account: ["_tag": "None"]))
        XCTAssertNil(anonymous?.account)
        XCTAssertEqual(anonymous?.repository(for: "/x/bot"), "bot")
        XCTAssertNil(GitHubTarget(discovery: discovery(status: "missing", auth: "authenticated", account: nil)))
        XCTAssertNil(GitHubTarget(discovery: discovery(status: "available", auth: "unauthenticated", account: nil)))
    }

    func testCloneProgressFindsItsProject() {
        let list: JSON = [
            ["projectId": "other", "phase": "running", "stage": "counting", "percent": nil, "detail": nil, "error": nil],
            ["projectId": "mine", "phase": "running", "stage": "receiving", "percent": 45, "detail": "12.3 MiB | 5.0 MiB/s", "error": nil],
        ]
        let progress = CloneProgress(projectId: "mine", in: list)
        XCTAssertEqual(progress?.percent, 45)
        XCTAssertEqual(progress?.summary, "Receiving objects · 45% · 12.3 MiB | 5.0 MiB/s")
        XCTAssertNil(CloneProgress(projectId: "gone", in: list))
    }
}

final class RefPageTests: XCTestCase {
    private func ref(_ name: String, current: Bool = false, isDefault: Bool = false, remote: Bool = false) -> JSON {
        ["name": .string(name), "current": .bool(current), "isDefault": .bool(isDefault), "isRemote": .bool(remote), "worktreePath": nil]
    }

    func testRequestTrimsQueryAndCarriesCursor() {
        let first = RefPage.request(cwd: "/repo", query: "  ")
        XCTAssertNil(first["query"])
        XCTAssertNil(first["cursor"])
        XCTAssertEqual(first["limit"]?.int, 100)
        XCTAssertEqual(first["refKind"]?.string, "local")
        let next = RefPage.request(cwd: "/repo", query: " feat/ ", cursor: 100)
        XCTAssertEqual(next["query"]?.string, "feat/")
        XCTAssertEqual(next["cursor"]?.int, 100)
    }

    func testPagesMergeByName() {
        let first = RefPage(json: ["refs": [ref("main", current: true), ref("dev")], "nextCursor": 2, "isRepo": true])
        let second = RefPage(json: ["refs": [ref("dev", isDefault: true), ref("feat/x")], "nextCursor": nil])
        XCTAssertEqual(first.nextCursor, 2)
        XCTAssertNil(second.nextCursor)
        let merged = RefPage.merge(first.refs, second.refs)
        XCTAssertEqual(merged.map(\.name), ["main", "dev", "feat/x"])
        XCTAssertTrue(merged[1].isDefault, "a ref seen again takes the newer value")
    }

    func testDefaultBasePrefersCurrentThenDefault() {
        XCTAssertEqual(RefPage(json: ["refs": [ref("dev"), ref("main", isDefault: true), ref("wip", current: true)]]).defaultBase, "wip")
        XCTAssertEqual(RefPage(json: ["refs": [ref("dev"), ref("main", isDefault: true)]]).defaultBase, "main")
        XCTAssertEqual(RefPage(json: ["refs": [ref("origin/x", current: true, remote: true), ref("dev")]]).defaultBase, "dev")
        XCTAssertNil(RefPage(json: ["refs": [], "isRepo": false]).defaultBase)
    }

    func testServerConfigReadsProjectRootsAndSettings() {
        let config = ServerConfig(json: [
            "environment": ["environmentId": "env"],
            "scratchWorkspaceRoot": "/Users/me/.t3/scratch",
            "settings": ["addProjectBaseDirectory": "  ", "newWorktreesStartFromOrigin": false],
        ])
        XCTAssertEqual(config?.scratchWorkspaceRoot, "/Users/me/.t3/scratch")
        XCTAssertNil(config?.newProjectsRoot)
        XCTAssertNil(config?.addProjectBaseDirectory)
        XCTAssertEqual(config?.newWorktreesStartFromOrigin, false)
        XCTAssertEqual(ServerConfig(json: ["environment": ["environmentId": "env"]])?.newWorktreesStartFromOrigin, true)
    }
}
