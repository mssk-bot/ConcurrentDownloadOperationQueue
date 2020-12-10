//
//  DownloadManager.swift

class DownloadManager: NSObject {
    
    typealias BackgroundTransferCompletionHandler = () -> ()
    
    //MARK:- Properties
    static let shared = DownloadManager()
    
    //MARK:--- Private Properties
    fileprivate var backgroundTransferCompletionHandlerDictionary = [String: BackgroundTransferCompletionHandler]()
    fileprivate var downloadSession: URLSession!
    fileprivate var downloadQ: OperationQueue! //Queue for handling all download operations
    
    //Using computed property with serial Q ensures thread safety
    fileprivate let historySerialQ = DispatchQueue(label: Constants.DownloadManager.HISTORY_SERIAL_QUEUE, attributes: [])
    fileprivate var _downloadHistory = [DownloadableItem]()
    fileprivate var downloadHistory: [DownloadableItem] {
        get {
            var result: [DownloadableItem]?
            historySerialQ.sync {
                result = self._downloadHistory
            }
            return result!
        }
        
        set {
            historySerialQ.sync {
                self._downloadHistory = newValue
            }
        }
    }
    
    
    //MARK:- Lifecycle methods
    override fileprivate init() {
        super.init()
        let backgroundSessionConfig = URLSessionConfiguration.background(withIdentifier: Constants.DownloadManager.BACKGROUND_DOWNLOAD_SESSION)
        backgroundSessionConfig.sessionSendsLaunchEvents = true
        downloadSession = URLSession(configuration: backgroundSessionConfig, delegate: self, delegateQueue: nil)
        
        downloadQ = OperationQueue()
        downloadQ.qualityOfService = .utility
        downloadQ.name = Constants.DownloadManager.DOWNLOAD_QUEUE
        downloadQ.maxConcurrentOperationCount = Constants.DownloadManager.MAX_CONCURRENT_DOWNLOAD_LIMIT
    }
    
    func resetInstance() {
        self.cancelAllTasks()
        self.downloadHistory.removeAll()
    }
    
    
    //MARK:- Public Methods
    func startDownload(for request: Downloader.Request) {
        DispatchQueue.global(qos: .userInitiated).async {
            var downloadableItems = self.getDownloadableItem(for: request.manifestItems)
            
            guard request.isReachable else {
                NotificationCenter.default.post(name: Notification.Name.DownloadManager.NetworkOfflineError,
                                                object: Downloader.Response(bookOfflineAccessType: request.bookOfflineAccessType,
                                                                            manifestItems: request.manifestItems,
                                                                            downloadableItems: downloadableItems))
                return
            }
            
            for (index, var downloadableItem) in downloadableItems.enumerated() {
                let manifestItem = request.manifestItems[index]
                
                let availaleFreeSpace = self.getAvailableFreeSpace() //TODO: Update space calculation logic
                let requiredFreeSpace = self.getSpaceRequiredForInProgressDownloads() + Int64(manifestItem.size)
                guard availaleFreeSpace > requiredFreeSpace else {
                    NotificationCenter.default.post(name: Notification.Name.DownloadManager.InsufficientSpaceError,
                                                    object: Downloader.Response(bookOfflineAccessType: request.bookOfflineAccessType,
                                                                                manifestItems: request.manifestItems,
                                                                                downloadableItems: downloadableItems,
                                                                                availableFreeSpace: availaleFreeSpace,
                                                                                requiredFreeSpace: requiredFreeSpace))
                    return
                }
                
                downloadableItem = self.startDownload(for: downloadableItem)
                downloadableItems[index] = downloadableItem
                self.updateDownloadHistory(with: downloadableItem)
                NotificationCenter.default.post(name: Notification.Name.DownloadManager.UpdateStatus,
                                                object: Downloader.Response(bookOfflineAccessType: request.bookOfflineAccessType,
                                                                            manifestItems: [manifestItem],
                                                                            downloadableItems: [downloadableItem]))
            }
        }
    }
    
    func stopDownload(for request: Downloader.Request) {
        DispatchQueue.global(qos: .userInitiated).async {
            var downloadableItems = self.getDownloadableItem(for: request.manifestItems)
            for (index, var downloadableItem) in downloadableItems.enumerated() {
                let manifestItem = request.manifestItems[index]
                
                if downloadableItem.status == .queued || downloadableItem.status == .inProgress {
                    downloadableItem.status = .paused
                    downloadableItem.operation?.task.suspend()
                    downloadableItems[index] = downloadableItem
                    self.updateDownloadHistory(with: downloadableItem)
                }
                
                let forcedState = downloadableItem.status == .completed ? false : nil
                
                NotificationCenter.default.post(name: Notification.Name.DownloadManager.UpdateStatus,
                                                object: Downloader.Response(bookOfflineAccessType: request.bookOfflineAccessType,
                                                                            manifestItems: [manifestItem],
                                                                            downloadableItems: [downloadableItem],
                                                                            forceToggleState: forcedState))
            }
            
            NotificationCenter.default.post(name: Notification.Name.DownloadManager.DownloadPaused,
                                            object: Downloader.Response(bookOfflineAccessType: request.bookOfflineAccessType,
                                                                        manifestItems: request.manifestItems,
                                                                        downloadableItems: downloadableItems))
        }
    }
    
    func resumeDownload(for request: Downloader.Request) {
        DispatchQueue.global(qos: .userInitiated).async {
            var downloadableItems = self.getDownloadableItem(for: request.manifestItems)
            for (index, var downloadableItem) in downloadableItems.enumerated() {
                let manifestItem = request.manifestItems[index]
                
                if downloadableItem.status == .paused {
                    downloadableItem.status = .inProgress
                    downloadableItem.operation?.task.resume()
                    downloadableItems[index] = downloadableItem
                    self.updateDownloadHistory(with: downloadableItem)
                }
                
                NotificationCenter.default.post(name: Notification.Name.DownloadManager.UpdateStatus,
                                                object: Downloader.Response(bookOfflineAccessType: request.bookOfflineAccessType,
                                                                            manifestItems: [manifestItem],
                                                                            downloadableItems: [downloadableItem]))
            }
        }
    }
    
    func removeDownload(for request: Downloader.Request) {
        DispatchQueue.global(qos: .userInitiated).async {
            let downloadableItems = self.getDownloadableItem(for: request.manifestItems)
            for (index, var downloadableItem) in downloadableItems.enumerated() {
                let manifestItem = request.manifestItems[index]
                
                downloadableItem.status = .notStarted
                downloadableItem.downloadProgress = 0.0
                downloadableItem.operation?.cancel()
                downloadableItem.operation = nil
                downloadableItem.taskIdentifier = -1
                if !self.removeDownloadedAsset(for: downloadableItem) {
                    ConsoleLog.error("Failed to remove file for item ===> \(downloadableItem)")
                }
                
                self.updateDownloadHistory(with: downloadableItem)
                
                if downloadableItem.assetType == .book {
                    let bookSetupWorker = BookSetupWorker()
                    bookSetupWorker.manifestStore = OfflineManifestStore()
                    bookSetupWorker.pageDataStore = PageDataStore()
                    bookSetupWorker.updateDowloadStatus(request: BookSetup.UpdateDownloadStatus.Request(bookId: downloadableItem.bookId,
                                                                                                        downloadableItem: downloadableItem,
                                                                                                        isDownloaded: false))
                }
                
                NotificationCenter.default.post(name: Notification.Name.DownloadManager.UpdateStatus,
                                                object: Downloader.Response(bookOfflineAccessType: request.bookOfflineAccessType,
                                                                            manifestItems: [manifestItem],
                                                                            downloadableItems: [downloadableItem]))
            }
        }
    }
    
    func cancelAllTasks() {
        let queuedDownloads = self.getAllQueuedDownloads()
        for downloadable in queuedDownloads {
            downloadable.operation?.cancel()
        }
    }
    
    
    //MARK:- Private operations handler methods
    fileprivate func startDownload(for item: DownloadableItem) -> DownloadableItem {
        var _downloadableItem = item
        switch _downloadableItem.status {
        case .notStarted:
            _downloadableItem.status = .queued
            
            guard let operation = self.createOperation(for: _downloadableItem) else {
                ConsoleLog.error("Unable to create operation for asset: \(_downloadableItem.assetId)")
                return _downloadableItem
            }
            
            _downloadableItem.operation = operation
            _downloadableItem.taskIdentifier = operation.task.taskIdentifier
            self.downloadQ.addOperation(operation)
            
        case .queued, .inProgress, .paused, .error:
            ConsoleLog.error("Trying to restart an already queued/inprogress/paused Download, cancelling failed download and restarting...")
            _downloadableItem.operation?.cancel()
            _downloadableItem.operation = nil
            _downloadableItem.taskIdentifier = -1
            _downloadableItem.status = .notStarted
            _downloadableItem.downloadProgress = 0.0
            _downloadableItem = self.startDownload(for: _downloadableItem)
            
        case .completed:
            ConsoleLog.error("Trying to restart a completed Downloadable!")
        }
        
        return _downloadableItem
    }
    
    fileprivate func removeDownloadedAsset(for item: DownloadableItem) -> Bool {
        let filePath = Constants.DirectoryPath.CACHES.appendingPathComponent("\(item.assetId)")
        if FileManager.default.fileExists(atPath: filePath) {
            do {
                try FileManager.default.removeItem(atPath: filePath)
            }
            catch let error as NSError {
                ConsoleLog.error("Unable to remove file at \(filePath) ::: with Error ===> \(error)")
                return false
            }
        }
        
        return true
    }
    
    fileprivate func createOperation(for item: DownloadableItem) -> DownloadOperation? {
        guard let url = URL(string: item.downloadSource), let urlRequest = APIManager.session.request(url).request else {
            print("Unable to start download for item: \(item)")
            return nil
        }

        switch item.assetType {
        case .book :
            let operation = BookDownloadOperation(session: downloadSession, urlRequest: urlRequest, downloadableItem: item)
            operation.delegate = self
            return operation
            
            /* Add cases for other asset types once required */
        default:
            return nil
        }
    }
    
    
    //MARK:- Public Helper methods
    func addBackgroundCompletionHander(_ completionHandler: @escaping BackgroundTransferCompletionHandler, forIdentifier identifier: String) {
        backgroundTransferCompletionHandlerDictionary[identifier] = completionHandler
    }
    
    func getDownloadableItem(for manifests: [OfflineManifestAsset]) -> [DownloadableItem] {
        var downloadables: [DownloadableItem] = []
        for manifest in manifests {
            downloadables.append(self.getDownloadableItem(for: manifest))
        }
        
        return downloadables
    }
    
    
    //MARK:- Private helper methods
    fileprivate func getAllQueuedDownloads() -> [DownloadableItem] {
        return self.downloadHistory.filter { $0.status == .inProgress || $0.status == .queued || $0.status == .paused }
    }
    
    fileprivate func getDownloadableItem(taskIdentifier: Int) -> DownloadableItem? {
        let downloads = self.downloadHistory.filter { $0.taskIdentifier == taskIdentifier }
        if !downloads.isEmpty {
            return downloads[0]
        }
        
        return nil
    }
    
    fileprivate func removeHistory(for downloadable: DownloadableItem) {
        for (index, item) in self.downloadHistory.enumerated() where item == downloadable {
            self.downloadHistory.remove(at: index)
            break
        }
    }
    
    fileprivate func getDownloadableItem(for manifest: OfflineManifestAsset) -> DownloadableItem {
        //TODO: Add logic to determine assetType when different assetTypes are implemented. For now, book is default.
        var download = DownloadableItem(bookId: manifest.bookId,
                                        assetId: manifest.assetId,
                                        assetType: .book,
                                        downloadSource: "\(manifest.baseUrl)\(manifest.src)",
            size: manifest.size,
            checksum: manifest.checksum ?? "")
        
        let previousDownloads = self.downloadHistory.filter { $0 == download }
        if previousDownloads.count > 1 {
            ConsoleLog.error("***** More than 1 downloadableItem found with matching parameters!!! *****")
        }
        
        if !previousDownloads.isEmpty {
            return previousDownloads[0]
        }
        
        if DataUtils.isAssetDownloaded(assetId: download.assetId) {
            download.status = .completed
            download.downloadProgress = 100
            download.taskIdentifier = -1
            download.operation = nil
        }
        
        self.downloadHistory.append(download)
        return download
    }
    
    fileprivate func updateDownloadHistory(with item: DownloadableItem) {
        if let index = self.downloadHistory.index(of: item) {
            self.downloadHistory[index] = item
        }
        else {
            self.downloadHistory.append(item)
        }
    }
    
    fileprivate func getSpaceRequiredForInProgressDownloads() -> Int64 {
        let totalSize = self.downloadHistory.filter { $0.status == .inProgress || $0.status == .queued || $0.status == .paused }.map { $0.size }.reduce(0, +)
        return Int64(totalSize)
    }
    
    fileprivate func getAvailableFreeSpace() -> Int64 {
        if let attributes = try? FileManager.default.attributesOfFileSystem(forPath: Constants.DirectoryPath.CACHES) {
            if let availableSize = attributes[FileAttributeKey.systemFreeSize] as? NSNumber {
                return availableSize.int64Value
            }
        }
        
        ConsoleLog.error("Unable to find available free space on device!!")
        return 0
    }
}


//MARK:- URLSession Delegate Extension
extension DownloadManager: URLSessionDelegate {
    
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        ConsoleLog.debug("Called!")
        session.getTasksWithCompletionHandler { [weak self] (dataTasks, uploadTasks, downloadTasks) in
            if downloadTasks.isEmpty {
                guard let `self` = self else { return }
                let backgroundDownloadCompletionHandler = self.backgroundTransferCompletionHandlerDictionary[Constants.DownloadManager.BACKGROUND_DOWNLOAD_SESSION]
                
                if let bgDownloadCompletionHandler = backgroundDownloadCompletionHandler {
                    self.backgroundTransferCompletionHandlerDictionary.removeValue(forKey: Constants.DownloadManager.BACKGROUND_DOWNLOAD_SESSION)
                    OperationQueue.main.addOperation({
                        bgDownloadCompletionHandler()
                        //Do other cleanup activities if required
                    })
                }
            }
        }
    }
}


//MARK:- URLSession Download Delegate Extension
extension DownloadManager: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if let downloadable = self.getDownloadableItem(taskIdentifier: downloadTask.taskIdentifier) {
            downloadable.operation?.urlSession(session, downloadTask: downloadTask, didWriteData: bytesWritten, totalBytesWritten: totalBytesWritten, totalBytesExpectedToWrite: totalBytesExpectedToWrite)
        }
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didResumeAtOffset fileOffset: Int64, expectedTotalBytes: Int64) {
        if let downloadable = self.getDownloadableItem(taskIdentifier: downloadTask.taskIdentifier) {
            downloadable.operation?.urlSession(session, downloadTask: downloadTask, didResumeAtOffset: fileOffset, expectedTotalBytes: expectedTotalBytes)
        }
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let downloadable = self.getDownloadableItem(taskIdentifier: downloadTask.taskIdentifier) {
            downloadable.operation?.urlSession(session, downloadTask: downloadTask, didFinishDownloadingTo: location)
        }
    }
}


//MARK:- DownloadOperationDelegate extension
extension DownloadManager: DownloadOperationDelegate {
    func operation(taskIdentifier: Int, progressInPercentage: Double) {
        ConsoleLog.debug("Task ID: \(taskIdentifier) ::: Progress: \(progressInPercentage)")
        if var downloadable = self.getDownloadableItem(taskIdentifier: taskIdentifier) {
            downloadable.status = .inProgress
            downloadable.downloadProgress = progressInPercentage
            self.updateDownloadHistory(with: downloadable)
            NotificationCenter.default.post(name: Notification.Name.DownloadManager.DownloadInProgress, object: downloadable)
        }
    }
    
    func operation(taskIdentifier: Int, didFinishDownloadTo location: URL) {
        ConsoleLog.debug("Task ID: \(taskIdentifier) ::: File saved to: \(location.absoluteString)")
        if var downloadable = self.getDownloadableItem(taskIdentifier: taskIdentifier) {
            downloadable.downloadProgress = 100.0
            downloadable.status = .completed
            downloadable.taskIdentifier = -1
            downloadable.operation = nil
            self.updateDownloadHistory(with: downloadable)
            
            //Finish Book Download Operation by setting up required data for offline use
            DispatchQueue.global(qos: .userInitiated).async {
                if downloadable.assetType == .book {
                    let bookSetupWorker = BookSetupWorker()
                    bookSetupWorker.manifestStore = OfflineManifestStore()
                    bookSetupWorker.pageDataStore = PageDataStore()
                    
                    bookSetupWorker.assignmentManager = AssignmentManager.sharedInstance
                    bookSetupWorker.bookModulesWorker = BookModulesWorker()
                    bookSetupWorker.bookMetaDataWorker = BookMetaDataWorker()
                    bookSetupWorker.mlgWorker = MLGlossaryXHTMLWorker()
                    bookSetupWorker.glossaryWorker = GlossaryWorker()
                    bookSetupWorker.promptStore = NotebookPromptDataStore()
                    bookSetupWorker.fileSystemManager = FileSystemManager.shared
                    bookSetupWorker.tocXhtmlWorker = TocXhtmlWorker(fileSystemManager: FileSystemManager.shared)
                    bookSetupWorker.packageOpfWorker = PackageOpfWorker(fileSystemManager: FileSystemManager.shared)
                    DispatchQueue.main.async {
                        if let book = BookshelfDataStore().fetchBook(forBookId: downloadable.bookId) {
                            bookSetupWorker.setupSupplementaryBookData(request: BookSetup.Request(book: book))
                        }
                    }
                    
                    let request = BookSetup.UpdateDownloadStatus.Request(bookId: downloadable.bookId, downloadableItem: downloadable, isDownloaded: true)
                    bookSetupWorker.updateDowloadStatus(request: request)
                }
            }
            
            NotificationCenter.default.post(name: Notification.Name.DownloadManager.DownloadComplete, object: downloadable)
        }
    }
    
    func operation(taskIdentifier: Int, didFinishDownloadWith error: Error?) {
        ConsoleLog.debug("Task ID: \(taskIdentifier) ::: File download finished with error: \(String(describing: error))")
        if var downloadable = self.getDownloadableItem(taskIdentifier: taskIdentifier) {
            downloadable.status = .error
            downloadable.downloadProgress = 0.0
            downloadable.taskIdentifier = -1
            downloadable.operation = nil
            self.updateDownloadHistory(with: downloadable)
            NotificationCenter.default.post(name: Notification.Name.DownloadManager.DownloadFailed, object: downloadable)
        }
    }
}
