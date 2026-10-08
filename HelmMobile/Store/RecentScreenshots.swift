import Observation
import Photos
import UIKit

/// The phone's latest screenshots, newest first, for the Mac remote's camera button.
@MainActor
@Observable
final class RecentScreenshots {
    struct Shot: Identifiable, Equatable {
        let asset: PHAsset
        var id: String { asset.localIdentifier }
        var createdAt: Date? { asset.creationDate }
    }

    private(set) var shots: [Shot] = []
    private(set) var thumbnails: [String: UIImage] = [:]
    /// Access to the photo library was refused.
    private(set) var denied = false
    private(set) var loaded = false

    @ObservationIgnored private let images = PHCachingImageManager()

    func load(limit: Int = 12) async {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined { status = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
        guard status == .authorized || status == .limited else {
            denied = true
            loaded = true
            return
        }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "(mediaSubtypes & %d) != 0", PHAssetMediaSubtype.photoScreenshot.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = limit
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var shots: [Shot] = []
        result.enumerateObjects { asset, _, _ in shots.append(Shot(asset: asset)) }
        self.shots = shots
        loaded = true
        for shot in shots { requestThumbnail(shot) }
    }

    private func requestThumbnail(_ shot: Shot) {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        images.requestImage(for: shot.asset, targetSize: CGSize(width: 600, height: 1300), contentMode: .aspectFit,
                            options: options) { [weak self] image, _ in
            guard let image else { return }
            Task { @MainActor in self?.thumbnails[shot.id] = image }
        }
    }

    /// The screenshot at full size, for upload.
    func fullImage(_ shot: Shot) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        return await withCheckedContinuation { continuation in
            images.requestImage(for: shot.asset, targetSize: PHImageManagerMaximumSize, contentMode: .default,
                                options: options) { image, info in
                // With .highQualityFormat the handler runs once.
                continuation.resume(returning: image)
            }
        }
    }
}
