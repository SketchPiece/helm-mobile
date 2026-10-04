import Foundation

/// Adding projects from the phone and listing branches. Each call resolves to a project that
/// is already in the shell, so the new-thread screen can select it straight away.
extension EnvironmentSession {
    struct ProjectNotShownError: LocalizedError {
        var errorDescription: String? { String(localized: "Helm made the project, but it hasn't shown up yet. Try again in a moment.") }
    }

    private func arrived(_ projectId: String) async throws -> Project {
        guard let project = await waitForProject(projectId) else { throw ProjectNotShownError() }
        return project
    }

    /// `projects.ensureScratch`: the environment's "no project" workspace, made on first use.
    func ensureScratchProject() async throws -> Project {
        let result = try await call("projects.ensureScratch", [:])
        guard let id = result["projectId"]?.string else { throw RPCError.defect("No project id") }
        return try await arrived(id)
    }

    func browseFolders(_ directory: String) async throws -> FolderListing {
        FolderListing(json: try await call("filesystem.browse", FolderListing.request(directory: directory)))
    }

    /// Adds a folder on the Mac as a project, or returns the project already rooted there.
    func addProject(folder path: String) async throws -> Project {
        if let existing = shell.projects.values.first(where: { $0.workspaceRoot == path }) { return existing }
        let result = try await call("projects.mutate", ProjectCommands.create(projectId: UUID().uuidString.lowercased(), path: path))
        guard let id = result["id"]?.string else { throw RPCError.defect("No project id") }
        return try await arrived(id)
    }

    /// `projects.createNew`: a folder under `newProjectsRoot` with a README and a first commit.
    /// `commitError` is why that first commit failed; the project exists anyway.
    func createNewProject(name: String) async throws -> (project: Project, commitError: String?) {
        let result = try await call("projects.createNew", ["name": .string(name)], timeout: .seconds(60))
        guard let id = result["projectId"]?.string else { throw RPCError.defect("No project id") }
        return (try await arrived(id), result["commitError"]?.nonNull?.string)
    }

    /// GitHub, when this Mac can create repositories on it.
    func gitHubTarget() async -> GitHubTarget? {
        guard let discovery = try? await call("server.discoverSourceControl", [:], timeout: .seconds(20)) else { return nil }
        return GitHubTarget(discovery: discovery)
    }

    /// Creates a private GitHub repository for a project and pushes it.
    func publishToGitHub(_ project: Project, target: GitHubTarget) async throws {
        _ = try await call("sourceControl.publishRepository", [
            "cwd": .string(project.workspaceRoot), "provider": "github",
            "repository": .string(target.repository(for: project.workspaceRoot)), "visibility": "private",
        ], timeout: .seconds(120))
    }

    func lookupGitHubRepository(_ nameWithOwner: String) async throws -> RepositoryInfo {
        let result = try await call("sourceControl.lookupRepository", ["provider": "github", "repository": .string(nameWithOwner)])
        guard let info = RepositoryInfo(json: result) else { throw RPCError.defect("No repository") }
        return info
    }

    private func clonePayload(_ source: CloneSource, repository: RepositoryInfo?, destination: String) -> [String: JSON] {
        var payload: [String: JSON] = [
            "remoteUrl": .string(repository?.cloneUrl ?? source.remoteUrl), "destinationPath": .string(destination),
        ]
        if let repository {
            payload["provider"] = .string(repository.provider)
            payload["repository"] = .string(repository.nameWithOwner)
        }
        return payload
    }

    /// `projectClone.start`: the project exists when this returns and the clone carries on in
    /// the background; follow it with `subscribeProjectClones`.
    func startClone(_ source: CloneSource, repository: RepositoryInfo?, destination: String) async throws -> String {
        var payload = clonePayload(source, repository: repository, destination: destination)
        let projectId = UUID().uuidString.lowercased()
        payload["projectId"] = .string(projectId)
        payload["title"] = .string(FolderPath.lastSegment(destination))
        payload["createdAt"] = .string(ISODate.string())
        _ = try await call("projectClone.start", .object(payload), timeout: .seconds(60))
        return projectId
    }

    /// Servers without clone tracking: clone in one blocking call, then add the folder.
    func cloneAndAdd(_ source: CloneSource, repository: RepositoryInfo?, destination: String) async throws -> Project {
        let result = try await call("sourceControl.cloneRepository", .object(clonePayload(source, repository: repository, destination: destination)),
                                    timeout: .seconds(600))
        return try await addProject(folder: result["cwd"]?.string ?? destination)
    }

    func retryClone(_ projectId: String) async throws {
        _ = try await call("projectClone.retry", ["projectId": .string(projectId)])
    }

    func listRefs(cwd: String, query: String = "", cursor: Int? = nil) async throws -> RefPage {
        RefPage(json: try await call("vcs.listRefs", RefPage.request(cwd: cwd, query: query, cursor: cursor)))
    }
}
