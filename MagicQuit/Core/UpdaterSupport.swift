import Foundation
import Sparkle

enum UpdaterSupport {
    static let controller: SPUStandardUpdaterController? = {
        #if DEBUG
        return nil
        #else
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              !key.isEmpty,
              let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              feed.contains("johnyoonh/magicquit") else {
            return nil
        }
        return SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        #endif
    }()
}
