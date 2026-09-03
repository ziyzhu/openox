import Photos
import UIKit

@MainActor
final class PhotoLibraryProvider {
    static let shared = PhotoLibraryProvider()

    struct AlbumRecord: Encodable {
        let id: String
        let title: String
        let assetCount: Int
        let canAddAssets: Bool
        let canRemoveAssets: Bool
    }

    struct AssetRecord: Encodable {
        let id: String
        let mediaType: String
        let createdAt: String?
        let modifiedAt: String?
        let width: Int
        let height: Int
        let duration: Double
        let isFavorite: Bool
        let subtypes: [String]
    }

    struct SearchPage: Encodable {
        let assets: [AssetRecord]
        let nextCursor: String?
        let totalCount: Int
    }

    struct PreviewLabel: Encodable {
        let label: String
        let assetID: String
    }

    struct Preview {
        let data: Data
        let labels: [PreviewLabel]
        let missingAssetIDs: [String]
    }

    struct AlbumMutation: Encodable {
        let albumID: String
        let changedCount: Int
        let missingAssetIDs: [String]
    }

    enum Failure: LocalizedError {
        case accessDenied
        case invalidDate(String)
        case invalidCursor
        case albumMissing
        case albumReadOnly
        case noAssets
        case previewUnavailable

        var errorDescription: String? {
            switch self {
            case .accessDenied:
                "Photos access is off for Ox. Ask the user to enable selected or full access in Settings › Privacy & Security › Photos › Ox, then try again."
            case .invalidDate(let field):
                "'\(field)' must be an ISO-8601 timestamp, e.g. 2026-06-25T09:00:00Z."
            case .invalidCursor:
                "'cursor' is no longer valid. Search the photo library again."
            case .albumMissing:
                "The requested photo album is unavailable. List albums again and retry with a current id."
            case .albumReadOnly:
                "The requested photo album doesn't allow this change. Choose a user-created album."
            case .noAssets:
                "No accessible photos matched the supplied asset ids."
            case .previewUnavailable:
                "Ox couldn't load previews for the requested photos. They may still be downloading from iCloud or no longer be shared with Ox."
            }
        }
    }

    private let library = PHPhotoLibrary.shared()
    private let imageManager = PHCachingImageManager()
    private let formatter = ISO8601DateFormatter()

    private init() {
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    static var authorizationStatus: PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    static func requestAccess() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    func listAlbums() async throws -> [AlbumRecord] {
        try await ensureAccess()
        let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
        var albums: [AlbumRecord] = []
        collections.enumerateObjects { collection, _, _ in
            let count = PHAsset.fetchAssets(in: collection, options: nil).count
            albums.append(AlbumRecord(
                id: collection.localIdentifier,
                title: collection.localizedTitle ?? "Untitled Album",
                assetCount: count,
                canAddAssets: collection.canPerform(.addContent),
                canRemoveAssets: collection.canPerform(.removeContent)
            ))
        }
        let sorted = albums.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        Log.agent.info("photos.albums count=\(sorted.count)")
        return sorted
    }

    func searchAssets(
        albumID: String?,
        mediaType: String?,
        from: String?,
        to: String?,
        favorite: Bool?,
        cursor: String?,
        limit: Int?
    ) async throws -> SearchPage {
        try await ensureAccess()
        let offset: Int
        if let cursor {
            guard let parsed = Int(cursor), parsed >= 0 else { throw Failure.invalidCursor }
            offset = parsed
        } else {
            offset = 0
        }
        let pageSize = min(max(limit ?? 50, 1), 200)
        let options = PHFetchOptions()
        options.includeHiddenAssets = false
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        var predicates: [NSPredicate] = []
        let requestedMediaType = mediaType ?? "image"
        if requestedMediaType != "any" {
            let rawValue: Int
            switch requestedMediaType {
            case "image": rawValue = PHAssetMediaType.image.rawValue
            case "video": rawValue = PHAssetMediaType.video.rawValue
            default: rawValue = PHAssetMediaType.unknown.rawValue
            }
            predicates.append(NSPredicate(format: "mediaType == %d", rawValue))
        }
        if let from {
            guard let date = ISODate.parse(from) else { throw Failure.invalidDate("from") }
            predicates.append(NSPredicate(format: "creationDate >= %@", date as NSDate))
        }
        if let to {
            guard let date = ISODate.parse(to) else { throw Failure.invalidDate("to") }
            predicates.append(NSPredicate(format: "creationDate <= %@", date as NSDate))
        }
        if let favorite {
            predicates.append(NSPredicate(format: "favorite == %@", NSNumber(value: favorite)))
        }
        if !predicates.isEmpty { options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates) }

        let result: PHFetchResult<PHAsset>
        if let albumID {
            guard let album = album(id: albumID) else { throw Failure.albumMissing }
            result = PHAsset.fetchAssets(in: album, options: options)
        } else {
            result = PHAsset.fetchAssets(with: options)
        }
        guard offset <= result.count else { throw Failure.invalidCursor }
        let end = min(offset + pageSize, result.count)
        let assets = (offset..<end).map { record(for: result.object(at: $0)) }
        let nextCursor = end < result.count ? String(end) : nil
        Log.agent.info("photos.search offset=\(offset) returned=\(assets.count) total=\(result.count)")
        return SearchPage(assets: assets, nextCursor: nextCursor, totalCount: result.count)
    }

    func previewAssets(ids: [String]) async throws -> Preview {
        try await ensureAccess()
        let requested = Array(ids.prefix(20))
        let assetsByID = assets(ids: requested)
        let ordered = requested.compactMap { id in assetsByID[id].map { (id, $0) } }
        guard !ordered.isEmpty else { throw Failure.noAssets }
        var images: [(String, UIImage)] = []
        for (id, asset) in ordered {
            try Task.checkCancellation()
            if let image = await thumbnail(for: asset) { images.append((id, image)) }
        }
        guard !images.isEmpty else { throw Failure.previewUnavailable }
        let labels = images.enumerated().map { index, value in
            PreviewLabel(label: "A\(index + 1)", assetID: value.0)
        }
        let data = try renderContactSheet(images: images.map(\.1), labels: labels.map(\.label))
        let included = Set(images.map(\.0))
        let missing = requested.filter { !included.contains($0) }
        Log.agent.info("photos.preview requested=\(requested.count) rendered=\(images.count) missing=\(missing.count)")
        return Preview(data: data, labels: labels, missingAssetIDs: missing)
    }

    func createAlbum(title: String) async throws -> AlbumRecord {
        try await ensureAccess()
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw RuntimeError.bridge("ios:photos:createAlbum: 'title' is required.") }
        final class IdentifierBox: @unchecked Sendable { var value: String? }
        let identifier = IdentifierBox()
        try await library.performChanges {
            identifier.value = PHAssetCollectionChangeRequest
                .creationRequestForAssetCollection(withTitle: value)
                .placeholderForCreatedAssetCollection.localIdentifier
        }
        guard let id = identifier.value, let created = album(id: id) else { throw Failure.albumMissing }
        Log.session.info("photos.album.create titleLength=\(value.count)")
        return AlbumRecord(id: id, title: value, assetCount: 0, canAddAssets: created.canPerform(.addContent), canRemoveAssets: created.canPerform(.removeContent))
    }

    func addAssets(ids: [String], toAlbum albumID: String) async throws -> AlbumMutation {
        try await mutateAssets(ids: ids, albumID: albumID, operation: .addContent, selectingExistingMembers: false) { request, assets in
            request.addAssets(assets)
        }
    }

    func removeAssets(ids: [String], fromAlbum albumID: String) async throws -> AlbumMutation {
        try await mutateAssets(ids: ids, albumID: albumID, operation: .removeContent, selectingExistingMembers: true) { request, assets in
            request.removeAssets(assets)
        }
    }

    private func mutateAssets(
        ids: [String],
        albumID: String,
        operation: PHCollectionEditOperation,
        selectingExistingMembers: Bool,
        change: @escaping (PHAssetCollectionChangeRequest, NSArray) -> Void
    ) async throws -> AlbumMutation {
        try await ensureAccess()
        let requested = Array(ids.prefix(200))
        guard let collection = album(id: albumID) else { throw Failure.albumMissing }
        guard collection.canPerform(operation) else { throw Failure.albumReadOnly }
        let byID = assets(ids: requested)
        guard !byID.isEmpty else { throw Failure.noAssets }
        let current = PHAsset.fetchAssets(in: collection, options: nil)
        var currentIDs = Set<String>()
        current.enumerateObjects { asset, _, _ in _ = currentIDs.insert(asset.localIdentifier) }
        let changing = requested.compactMap { id -> PHAsset? in
            guard let asset = byID[id], currentIDs.contains(id) == selectingExistingMembers else { return nil }
            return asset
        }
        if !changing.isEmpty {
            try await library.performChanges {
                guard let request = PHAssetCollectionChangeRequest(for: collection) else { return }
                change(request, changing as NSArray)
            }
        }
        let missing = requested.filter { byID[$0] == nil }
        Log.session.info("photos.album.mutate operation=\(String(describing: operation)) changed=\(changing.count) missing=\(missing.count)")
        return AlbumMutation(albumID: albumID, changedCount: changing.count, missingAssetIDs: missing)
    }

    private func ensureAccess() async throws {
        let current = Self.authorizationStatus
        Log.agent.info("photos.authorization status=\(Self.authorizationName(current))")
        switch current {
        case .authorized, .limited: return
        case .notDetermined:
            let status = await Self.requestAccess()
            Log.agent.info("photos.authorization requested=\(Self.authorizationName(status))")
            guard status == .authorized || status == .limited else { throw Failure.accessDenied }
        case .denied, .restricted: throw Failure.accessDenied
        @unknown default: throw Failure.accessDenied
        }
    }

    private static func authorizationName(_ status: PHAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: "notDetermined"
        case .restricted: "restricted"
        case .denied: "denied"
        case .authorized: "authorized"
        case .limited: "limited"
        @unknown default: "unknown"
        }
    }

    private func album(id: String) -> PHAssetCollection? {
        PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject
    }

    private func assets(ids: [String]) -> [String: PHAsset] {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var byID: [String: PHAsset] = [:]
        result.enumerateObjects { asset, _, _ in byID[asset.localIdentifier] = asset }
        return byID
    }

    private func record(for asset: PHAsset) -> AssetRecord {
        var subtypes: [String] = []
        if asset.mediaSubtypes.contains(.photoScreenshot) { subtypes.append("screenshot") }
        if asset.mediaSubtypes.contains(.photoLive) { subtypes.append("livePhoto") }
        if asset.mediaSubtypes.contains(.photoPanorama) { subtypes.append("panorama") }
        if asset.mediaSubtypes.contains(.videoHighFrameRate) { subtypes.append("highFrameRate") }
        if asset.mediaSubtypes.contains(.videoTimelapse) { subtypes.append("timelapse") }
        let type = switch asset.mediaType {
        case .image: "image"
        case .video: "video"
        case .audio: "audio"
        case .unknown: "unknown"
        @unknown default: "unknown"
        }
        return AssetRecord(
            id: asset.localIdentifier,
            mediaType: type,
            createdAt: asset.creationDate.map(formatter.string),
            modifiedAt: asset.modificationDate.map(formatter.string),
            width: asset.pixelWidth,
            height: asset.pixelHeight,
            duration: asset.duration,
            isFavorite: asset.isFavorite,
            subtypes: subtypes
        )
    }

    private func thumbnail(for asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true
            imageManager.requestImage(
                for: asset,
                targetSize: CGSize(width: 480, height: 480),
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                if (info?[PHImageCancelledKey] as? Bool) == true {
                    continuation.resume(returning: nil)
                    return
                }
                if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                continuation.resume(returning: image)
            }
        }
    }

    private func renderContactSheet(images: [UIImage], labels: [String]) throws -> Data {
        let columns = 4
        let cell = CGSize(width: 300, height: 300)
        let rows = Int(ceil(Double(images.count) / Double(columns)))
        let canvas = CGSize(width: cell.width * CGFloat(columns), height: cell.height * CGFloat(rows))
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: canvas, format: format)
        let rendered = renderer.image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: canvas))
            for (index, image) in images.enumerated() {
                let column = index % columns
                let row = index / columns
                let frame = CGRect(x: CGFloat(column) * cell.width, y: CGFloat(row) * cell.height, width: cell.width, height: cell.height)
                    .insetBy(dx: 3, dy: 3)
                context.cgContext.saveGState()
                context.cgContext.clip(to: frame)
                let scale = max(frame.width / image.size.width, frame.height / image.size.height)
                let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                image.draw(in: CGRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height))
                context.cgContext.restoreGState()
                let label = labels[index] as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.monospacedSystemFont(ofSize: 28, weight: .bold),
                    .foregroundColor: UIColor.white,
                    .backgroundColor: UIColor.black.withAlphaComponent(0.72),
                ]
                label.draw(at: CGPoint(x: frame.minX + 10, y: frame.minY + 8), withAttributes: attributes)
            }
        }
        guard let data = rendered.jpegData(compressionQuality: 0.82) else { throw Failure.previewUnavailable }
        return data
    }
}
