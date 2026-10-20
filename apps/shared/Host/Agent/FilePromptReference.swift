import Foundation

nonisolated enum FilePromptReference {
    static func text(for file: FileItem) -> String {
        let fields = [
            "filename": file.fileName,
            "mimeType": file.mimeType,
            "path": "artifacts/\(file.fileName)",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return "Available file: artifacts/\(file.fileName)"
        }
        return "Available file: \(json)"
    }
}
