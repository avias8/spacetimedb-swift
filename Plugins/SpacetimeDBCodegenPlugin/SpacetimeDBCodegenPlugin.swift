import Foundation
import PackagePlugin

/// A Swift Package Manager Build Tool Plugin that automatically invokes `spacetime generate --lang swift`
/// when a `spacetime-codegen.json` configuration file is present in the target's source directory.
///
/// ### Configuration (`spacetime-codegen.json`)
/// Place a `spacetime-codegen.json` file in your target's directory:
/// ```json
/// {
///   "modulePath": "../server-module",
///   "spacetimeExecutable": "spacetime",
///   "extraArguments": []
/// }
/// ```
/// If `spacetime-codegen.json` is not present in a target, the plugin is a no-op.
@main
struct SpacetimeDBCodegenPlugin: BuildToolPlugin {
    struct Configuration: Decodable {
        var modulePath: String?
        var binPath: String?
        var spacetimeExecutable: String?
        var extraArguments: [String]?
    }

    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        guard let sourceTarget = target as? SourceModuleTarget else {
            return []
        }

        let configURL = sourceTarget.directoryURL.appending(path: "spacetime-codegen.json")
        guard FileManager.default.fileExists(atPath: configURL.path()) else {
            return []
        }

        let configData = try Data(contentsOf: configURL)
        let config = try JSONDecoder().decode(Configuration.self, from: configData)

        let outputDir = context.pluginWorkDirectoryURL.appending(path: "SpacetimeGenerated")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let executableURL = try resolveExecutable(named: config.spacetimeExecutable ?? "spacetime", in: context)

        var arguments: [String] = [
            "generate",
            "--lang", "swift",
            "--out-dir", outputDir.path(),
        ]

        var inputFiles: [URL] = [configURL]

        if let modulePath = config.modulePath {
            let resolvedURL = URL(filePath: modulePath, relativeTo: sourceTarget.directoryURL).standardizedFileURL
            arguments.append(contentsOf: ["--project-path", resolvedURL.path()])
        } else if let binPath = config.binPath {
            let resolvedURL = URL(filePath: binPath, relativeTo: sourceTarget.directoryURL).standardizedFileURL
            arguments.append(contentsOf: ["--bin-path", resolvedURL.path()])
            inputFiles.append(resolvedURL)
        } else {
            Diagnostics.error("spacetime-codegen.json must specify either 'modulePath' or 'binPath'.")
            return []
        }

        if let extra = config.extraArguments {
            arguments.append(contentsOf: extra)
        }

        return [
            .prebuildCommand(
                displayName: "Generate SpacetimeDB Swift Bindings for \(target.name)",
                executable: executableURL,
                arguments: arguments,
                outputFilesDirectory: outputDir
            )
        ]
    }

    private func resolveExecutable(named name: String, in context: PluginContext) throws -> URL {
        if name.contains("/") {
            return URL(filePath: name)
        }
        if let tool = try? context.tool(named: name) {
            return tool.url
        }
        let searchPaths = [
            FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin/\(name)").path(),
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
        ]
        for path in searchPaths where FileManager.default.isExecutableFile(atPath: path) {
            return URL(filePath: path)
        }
        return URL(filePath: "/usr/bin/env")
    }
}
