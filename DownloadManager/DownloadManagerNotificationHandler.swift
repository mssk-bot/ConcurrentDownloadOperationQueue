//
//  DownloadManagerNotificationHandler.swift

protocol DownloadManagerNotificationViewControllerInput: class {
    func displayUpdatedViewModel(_ viewModel: Download.ViewModel)

    func displayDownloadCancellationAlert(title: String, message: String, forAssets assetIds: [String])
    func displayError(title: String?, message: String?)
}

//MARK:- DownloadManagerNotificationPresenter Protocol
protocol DownloadManagerNotificationPresenter: class {
    var notificationViewController: DownloadManagerNotificationViewControllerInput! { get }

    func presentUpdate(request: Download.ViewModelUpdate.Request)
    func presentOfflineError()
    func presentInsufficientSpaceError(assetSize: String, availableSize: String)
    func presentChapterDownloadCancellationMessage(forAssets assetIds: [String])
    func presentBookDownloadCancellationMessage(forAssets assetIds: [String])
}

//MARK:- DownloadManagerNotificationPresenter Protocol Extension
extension DownloadManagerNotificationPresenter {
    func presentUpdate(request: Download.ViewModelUpdate.Request) {
        notificationViewController?.displayUpdatedViewModel(Download.ViewModel(bookId: request.manifestItem.bookId,
                                                                               bookTitle: request.manifestItem.title,
                                                                               bookOfflineAccessType: request.offlineAccessType,
                                                                               baseUrl: request.manifestItem.baseUrl,
                                                                               sourceUrl: request.manifestItem.src,
                                                                               size: request.downloadableItem.size,
                                                                               checksum: request.downloadableItem.checksum,
                                                                               chapterIndex: request.manifestItem.chapterIndex,
                                                                               assetId: request.manifestItem.assetId,
                                                                               progress: request.downloadableItem.downloadProgress,
                                                                               status: request.downloadableItem.status,
                                                                               isDownloaded: (request.downloadableItem.status == .completed),
                                                                               toggleSwitchState: request.forcedToggleSwitchState ?? (request.downloadableItem.status == .queued ||
                                                                                                                                        request.downloadableItem.status == .inProgress ||
                                                                                                                                        request.downloadableItem.status == .completed)))
    }

    func presentOfflineError() {
        notificationViewController?.displayError(title: NSLocalizedString("Offline", comment: "Offline"),
                                                 message: NSLocalizedString("Unable to download asset, it appears that your internet is currently offline. Please try again when the device is online.", comment: "Unable to download asset, it appears that your internet is currently offline. Please try again when the device is online."))
    }

    func presentInsufficientSpaceError(assetSize: String, availableSize: String) {
        notificationViewController?.displayError(title: NSLocalizedString("Insufficient Space", comment: "Insufficient Space"),
                                                 message: String(format: "Cannot download asset. You do not have sufficient space. Asset size: %@, space available: %@.", assetSize, availableSize))
    }

    func presentChapterDownloadCancellationMessage(forAssets assetIds: [String]) {
        notificationViewController?.displayDownloadCancellationAlert(title: NSLocalizedString("Remove Chapter?", comment: "Remove Chapter?"),
                                                                     message: NSLocalizedString("You are about to remove the downloaded version of this chapter from your bookshelf. Are you sure you want to do this?", comment: "You are about to remove the downloaded version of this chapter from your bookshelf. Are you sure you want to do this?"),
                                                                     forAssets: assetIds)
    }

    func presentBookDownloadCancellationMessage(forAssets assetIds: [String]) {
        notificationViewController?.displayDownloadCancellationAlert(title: NSLocalizedString("Remove Book?", comment: "Remove Book?"),
                                                                     message: NSLocalizedString("You are about to remove the downloaded version of this book from your bookshelf. Are you sure you want to do this?", comment: "You are about to remove the downloaded version of this book from your bookshelf. Are you sure you want to do this?"),
                                                                     forAssets: assetIds)
    }
}


//MARK:- DownloadManagerNotificationHandler Protocol
protocol DownloadManagerNotificationHandler: class {
    var notificationPresenter: DownloadManagerNotificationPresenter! { get }
    var offlineAccessType: BookOfflineAccessType? { get }

    func handleDownloadProgress(notification: Notification)
    func handleNetworkOfflineError(notification: Notification)
    func handleInsufficientSpaceError(notification: Notification)
    func handleDownloadStatusUpdate(notification: Notification)
    func handleDownloadPaused(notification: Notification)

    func getManifests(forAssetIds assetIds: [String], bookId: String) -> [OfflineManifestAsset]?
}

//MARK:- DownloadManagerNotificationHandler Protocol Extension
extension DownloadManagerNotificationHandler {

    func handleDownloadProgress(notification: Notification) {
        if let downloadableItem = notification.object as? DownloadableItem {
            if let manifestItems = self.getManifests(forAssetIds: [downloadableItem.assetId], bookId: downloadableItem.bookId), !manifestItems.isEmpty {
                if let offlineAccessType = self.offlineAccessType {
                    self.notificationPresenter.presentUpdate(request: Download.ViewModelUpdate.Request(offlineAccessType: offlineAccessType, manifestItem: manifestItems[0], downloadableItem: downloadableItem))
                }
            }
        }
    }

    func handleNetworkOfflineError(notification: Notification) {
        self.handleDownloadStatusUpdate(notification: notification)
        self.notificationPresenter.presentOfflineError()
    }

    func handleInsufficientSpaceError(notification: Notification) {
        if let response = notification.object as? Downloader.Response {
            self.handleDownloadStatusUpdate(notification: notification)
            self.notificationPresenter.presentInsufficientSpaceError(assetSize: String(response.requiredFreeSpace), availableSize: String(response.availableFreeSpace))
        }
    }

    func handleDownloadStatusUpdate(notification: Notification) {
        if let response = notification.object as? Downloader.Response {
            for downloadableItem in response.downloadableItems {
                if let manifestItems = self.getManifests(forAssetIds: [downloadableItem.assetId], bookId: downloadableItem.bookId) {
                    self.notificationPresenter.presentUpdate(request: Download.ViewModelUpdate.Request(offlineAccessType: response.bookOfflineAccessType, manifestItem: manifestItems[0], downloadableItem: downloadableItem, forcedToggleSwitchState: response.forceToggleState))
                }
            }
        }
    }

    func handleDownloadPaused(notification: Notification) {
        if let response = notification.object as? Downloader.Response {
            var assetIds = [String]()
            for downloadableItem in response.downloadableItems {
                if let manifestItems = self.getManifests(forAssetIds: [downloadableItem.assetId], bookId: downloadableItem.bookId) {
                    assetIds.append(manifestItems[0].assetId)
                }
            }

            if response.bookOfflineAccessType == .chunkedEpub {
                self.notificationPresenter.presentChapterDownloadCancellationMessage(forAssets: assetIds)
            } else {
                self.notificationPresenter.presentBookDownloadCancellationMessage(forAssets: assetIds)
            }
        }
    }
}
