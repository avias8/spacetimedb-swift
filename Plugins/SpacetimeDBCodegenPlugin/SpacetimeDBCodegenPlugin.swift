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

        let configPath = sourceTarget.directory.appending(subpath: "spacetime-codegen.json")
        guard FileManager.default.fileExists(atPath: configPath.string) else {
            return []
        }

        let configData = try Data(contentsOf: URL(fileURLWithPath: configPath.string))
        let config = try JSONDecoder().decode(Configuration.self, from: configData)

        let outputDir = context.pluginWorkDirectory.appending(subpath: "SpacetimeGenerated")
        try FileManager.default.createDirectory(atPath: outputDir.string, withIntermediateDirectories: true)

        let executablePath = try resolveExecutable(named: config.spacetimeExecutable ?? "spacetime", in: context)

        var arguments: [String] = [
            "generate",
            "--lang", "swift",
            "--out-dir", outputDir.string,
        ]

        if let modulePath = config.modulePath {
            let targetURL = URL(fileURLWithPath: sourceTarget.directory.string)
            let resolvedURL = URL(fileURLWithPath: modulePath, relativeTo: targetURL).standardized
            arguments.append(contentsOf: ["--project-path", resolvedURL.path])
        } else if let binPath = config.binPath {
            let targetURL = URL(fileURLWithPath: sourceTarget.directory.string)
            let resolvedURL = URL(fileURLWithPath: binPath, relativeTo: targetURL).standardized
            arguments.append(contentsOf: ["--bin-path", resolvedURL.path])
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
                executable: executablePath,
                arguments: arguments,
                outputFilesDirectory: outputDir
            )
        ]
    }

    private func resolveExecutable(named name: String, in context: PluginContext) throws -> Path {
        if name.contains("/") {
            return Path(name)
        }
        if let tool = try? context.tool(named: name) {
            return tool.path
        }
        let searchPaths = [
            FileManager.default.homeDirectoryForCurrentUser.path + "/.local/bin/\(name)",
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
        ]
        for path in searchPaths where FileManager.default.isExecutableFile(atPath: path) {
            return Path(path)
        }
        return Path("/usr/bin/env")
    }
}
