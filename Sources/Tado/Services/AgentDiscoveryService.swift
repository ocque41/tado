import Foundation

enum AgentDiscoveryService {
    static func discover(projectRoot: String) -> [AgentDefinition] {
        let rootURL = URL(fileURLWithPath: projectRoot)
        let fm = FileManager.default

        var results: [AgentDefinition] = []

        let sources: [(path: String, source: AgentDefinition.AgentSource)] = [
            (".claude/agents", .claude),
            (".codex/agents", .codex),
        ]

        for (subpath, source) in sources {
            let dir = rootURL.appendingPathComponent(subpath)
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
                continue
            }
            for file in files where file.pathExtension == "md" {
                let stem = file.deletingPathExtension().lastPathComponent
                let agent = AgentDefinition(id: stem, filePath: file.path, source: source)
                results.append(agent)
            }
        }

        return results.sorted { $0.name < $1.name }
    }
}
