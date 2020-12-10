//
//  DownloadManagerModels.swift

enum DownloadAssetType: Int {
    case book   = 0
    case zip    = 1
    case pdf    = 2
}

enum DownloadStatus: Int {
    case notStarted = 0
    case queued     = 1
    case inProgress = 2
    case paused     = 3
    case completed  = 4
    case error      = 5
}

enum DownloadError: Error {
    case moveFileToCacheFailed(String)
    case zipUnarchiveFailed(String)
    case updateManifestStatusFailed
    case updatePageStatusFailed
}


struct DownloadableItem {
    //MARK:- Properties
    let bookId: String
    let assetId: String
    let assetType: DownloadAssetType
    let downloadSource: String
    let size: Int
    let checksum: String

    var status: DownloadStatus = .notStarted
    var downloadProgress: Double = 0.0
    var taskIdentifier: Int? = -1
    var taskResumeData: Data? = nil
    var operation: DownloadOperation?

    //MARK:- Initializers
    init(bookId: String, assetId: String, assetType: DownloadAssetType, downloadSource: String, size: Int, checksum: String) {
        self.bookId = bookId
        self.assetId = assetId
        self.assetType = assetType
        self.downloadSource = downloadSource
        self.size = size
        self.checksum = checksum
    }
}


//MARK:- Equatable protocol methods
extension DownloadableItem: Equatable {
    static func ==(lhs: DownloadableItem, rhs: DownloadableItem) -> Bool {
        return lhs.bookId == rhs.bookId && lhs.assetId == rhs.assetId && lhs.checksum == rhs.checksum && lhs.downloadSource == rhs.downloadSource && lhs.size == rhs.size
    }
}


//MARK:- Request/Response models
struct Downloader {
    struct Request {
        let isReachable: Bool
        let bookOfflineAccessType: BookOfflineAccessType
        let manifestItems: [OfflineManifestAsset]
    }

    struct Response {
        let bookOfflineAccessType: BookOfflineAccessType
        let manifestItems: [OfflineManifestAsset]
        let downloadableItems: [DownloadableItem]
        let forceToggleState: Bool?
        let availableFreeSpace: Int64
        let requiredFreeSpace: Int64

        init(bookOfflineAccessType: BookOfflineAccessType, manifestItems: [OfflineManifestAsset], downloadableItems: [DownloadableItem], forceToggleState: Bool? = nil, availableFreeSpace: Int64 = 0, requiredFreeSpace: Int64 = 0) {

            self.bookOfflineAccessType = bookOfflineAccessType
            self.manifestItems = manifestItems
            self.downloadableItems = downloadableItems
            self.forceToggleState = forceToggleState
            self.availableFreeSpace = availableFreeSpace
            self.requiredFreeSpace = requiredFreeSpace
        }
    }
}
