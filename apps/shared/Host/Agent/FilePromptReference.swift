import Foundation

nonisolated enum FilePromptReference {
    static func text(for artifact: FileItem) -> String {
        let fields = [
            "filename": artifact.fileName,
            "mimeType": artifact.mimeType,
            "path": "artifacts/\(artifact.fileName)",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return "Available file: artifacts/\(artifact.fileName)"
        }
        return "Available file: \(json)"
    }
}
