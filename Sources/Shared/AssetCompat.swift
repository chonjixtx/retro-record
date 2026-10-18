import AVFoundation
import CoreMedia

/// AVAsset 的 async 加载 API（load / loadTracks）是 iOS 16.0 才有的。
/// 部署目标降到 15.4 后，老系统必须走 loadValuesAsynchronously 回调版，
/// 否则一启动就会因为找不到符号直接崩（典型症状：点开秒退、无提示）。
public enum AssetCompat {

    public static func duration(of asset: AVAsset) async -> CMTime {
        if #available(iOS 16.0, *) {
            return (try? await asset.load(.duration)) ?? .invalid
        } else {
            return await withCheckedContinuation { continuation in
                asset.loadValuesAsynchronously(forKeys: [#keyPath(AVAsset.duration)]) {
                    var error: NSError?
                    let status = asset.statusOfValue(forKey: #keyPath(AVAsset.duration), error: &error)
                    continuation.resume(returning: status == .loaded ? asset.duration : .invalid)
                }
            }
        }
    }

    public static func videoTracks(of asset: AVAsset) async -> [AVAssetTrack] {
        if #available(iOS 16.0, *) {
            return (try? await asset.loadTracks(withMediaType: .video)) ?? []
        } else {
            return await withCheckedContinuation { continuation in
                asset.loadValuesAsynchronously(forKeys: [#keyPath(AVAsset.tracks)]) {
                    continuation.resume(returning: asset.tracks(withMediaType: .video))
                }
            }
        }
    }

    public static func audioTracks(of asset: AVAsset) async -> [AVAssetTrack] {
        if #available(iOS 16.0, *) {
            return (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        } else {
            return await withCheckedContinuation { continuation in
                asset.loadValuesAsynchronously(forKeys: [#keyPath(AVAsset.tracks)]) {
                    continuation.resume(returning: asset.tracks(withMediaType: .audio))
                }
            }
        }
    }

    public static func preferredTransform(of track: AVAssetTrack) async -> CGAffineTransform {
        if #available(iOS 16.0, *) {
            return (try? await track.load(.preferredTransform)) ?? .identity
        } else {
            return await withCheckedContinuation { continuation in
                track.loadValuesAsynchronously(forKeys: [#keyPath(AVAssetTrack.preferredTransform)]) {
                    continuation.resume(returning: track.preferredTransform)
                }
            }
        }
    }
}
