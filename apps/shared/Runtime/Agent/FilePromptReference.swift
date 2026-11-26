import Foundation

nonisolated enum FilePromptReference {
    static func text(for file: FileItem) -> String {
        var fields = [
            "filename": file.displayName,
            "mimeType": file.mimeType,
        ]
        if let path = file.virtualPath { fields["path"] = path }
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return "Available file: \(file.displayName)"
        }
        return "Available file: \(json)"
    }
}
