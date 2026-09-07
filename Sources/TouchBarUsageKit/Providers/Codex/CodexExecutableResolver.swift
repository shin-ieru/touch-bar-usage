import Foundation

/// Finds the Codex CLI on this machine.
///
/// Deliberately checks several locations rather than hard-coding one: Codex ships
/// standalone, via Homebrew on both architectures, and bundled inside the OpenAI
/// editor extensions. Any of them is a legitimate install.
public protocol CodexExecutableResolving: Sendable {
    func executablePath() -> String?
}

public struct CodexExecutableResolver: CodexExecutableResolving {

    /// Overrides everything else, for development against a specific build.
    public static let overrideEnvironmentKey = "TBU_CODEX_PATH"

    private let fileManager: FileManager
    private let environment: [String: String]
    private let home: URL

    public init(fileManager: FileManager = .default,
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.fileManager = fileManager
        self.environment = environment
        self.home = fileManager.homeDirectoryForCurrentUser
    }

    public func executablePath() -> String? {
        for candidate in candidates() where isExecutable(candidate) {
            return candidate
        }
        return nil
    }

    /// In preference order: explicit override, PATH, standard install locations,
    /// then editor extensions.
    func candidates() -> [String] {
        var paths: [String] = []

        if let override = environment[Self.overrideEnvironmentKey], !override.isEmpty {
            paths.append(override)
        }

        paths.append(contentsOf: pathEntries())

        paths.append(contentsOf: [
            "/opt/homebrew/bin/codex",                       // Apple silicon Homebrew
            "/usr/local/bin/codex",                          // Intel Homebrew
            home.appendingPathComponent(".local/bin/codex").path,
            home.appendingPathComponent(".codex/bin/codex").path,
            home.appendingPathComponent(".bun/bin/codex").path,
            "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex",
            "/usr/local/lib/node_modules/@openai/codex/bin/codex",
        ])

        paths.append(contentsOf: editorExtensionCandidates())
        return paths
    }

    /// Resolves `codex` against the inherited PATH without spawning a shell.
    private func pathEntries() -> [String] {
        guard let path = environment["PATH"] else { return [] }
        return path.split(separator: ":").map { "\($0)/codex" }
    }

    /// The OpenAI editor extensions bundle a platform-specific `codex` binary.
    /// Newest extension version wins, and the architecture directory is matched
    /// rather than assumed.
    private func editorExtensionCandidates() -> [String] {
        let roots = [
            home.appendingPathComponent(".vscode/extensions"),
            home.appendingPathComponent(".vscode-insiders/extensions"),
            home.appendingPathComponent(".cursor/extensions"),
            home.appendingPathComponent(".vscode-oss/extensions"),
            home.appendingPathComponent(".windsurf/extensions"),
        ]
        let architectures = ["macos-aarch64", "macos-x86_64"]

        var results: [String] = []
        for root in roots {
            guard let contents = try? fileManager.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil) else { continue }
            let extensions = contents
                .filter { $0.lastPathComponent.hasPrefix("openai.chatgpt-") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .reversed()
            for ext in extensions {
                for architecture in architectures {
                    results.append(ext.appendingPathComponent("bin/\(architecture)/codex").path)
                }
            }
        }
        return results
    }

    private func isExecutable(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return false }
        return fileManager.isExecutableFile(atPath: path)
    }
}

/// Test double.
public struct StubCodexExecutableResolver: CodexExecutableResolving {
    private let path: String?
    public init(path: String?) { self.path = path }
    public func executablePath() -> String? { path }
}
