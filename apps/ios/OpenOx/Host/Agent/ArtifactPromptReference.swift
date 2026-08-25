import Foundation

nonisolated enum ArtifactPromptReference {
    static func text(for artifact: Artifact) -> String {
        let fields = [
            "filename": artifact.fileName,
            "mimeType": artifact.mimeType,
            "path": "artifacts/\(artifact.fileName)",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return "Attached artifact: artifacts/\(artifact.fileName)"
        }
        return "Attached artifact: \(json)"
    }
}
