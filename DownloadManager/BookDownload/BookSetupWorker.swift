//
//  BookSetupWorker.swift

import SwiftyJSON

class BookSetupWorker {
    
    //MARK:- Properties
    var bookModulesWorker: BookModulesWorker!
    var bookMetaDataWorker: BookMetaDataWorker!
    var bookProfileWorker: BookProfileWorker!
    var tocWorker: TableOfContentsWorker!
    var manifestWorker: OfflineManifestWorker!
    var mlgWorker: MLGlossaryWorker!
    var glossaryWorker: GlossaryWorker!
    var manifestStore: OfflineManifestStore!
    var customBasketDataStore: CustomBasketDataStore!
    var pageDataStore: PageDataStore!
    var assignmentManager: AssignmentManager!
    var promptStore: NotebookPromptDataStore!
    var fileSystemManager: FileSystemManager!
    var tocXhtmlWorker: TocXhtmlWorker!
    var packageOpfWorker: PackageOpfWorker!
    
    private let environment = StoredProperties.Common.environment
    
    //MARK:- Lifecycle methods
    deinit {
        self.bookModulesWorker = nil
        self.bookMetaDataWorker = nil
        self.bookProfileWorker = nil
        self.tocWorker = nil
        self.manifestWorker = nil
        self.mlgWorker = nil
        self.glossaryWorker = nil
        self.manifestStore = nil
        self.customBasketDataStore = nil
        self.pageDataStore = nil
        self.assignmentManager = nil
        self.tocXhtmlWorker = nil
        self.packageOpfWorker = nil
        self.fileSystemManager = nil
    }
    
    //MARK:- Public methods
    func updateDowloadStatus(request: BookSetup.UpdateDownloadStatus.Request) {
        DispatchQueue.main.async {

            //Update download status in pageDataStore
            self.pageDataStore.updateDownloadStatus(request.isDownloaded, bookId: request.bookId, assetId: request.downloadableItem.assetId){ (statusUpdated) in
                if (statusUpdated) {
                    //Update download status in manifestStore
                    self.manifestStore.updateDownloadStatus(request.isDownloaded, bookId: request.bookId, assetId: request.downloadableItem.assetId) { (statusUpdated) in
                        if (statusUpdated) {
                            //TODO_GROOT: Use this notification
                            NotificationCenter.default.post(name: Notification.Name.DownloadManager.DownloadStatusChanged, object: request.downloadableItem)
                        } else {
                            self.pageDataStore.updateDownloadStatus(!request.isDownloaded, bookId: request.bookId, assetId: request.downloadableItem.assetId){ _ in ConsoleLog.error("Update download status in manifestStore failed!!!") }
                        }
                    }
                } else {
                    ConsoleLog.error("Update download status in pageDataStore failed!!!")
                }
            }
        }
    }
    
    func setupManifest(request: BookSetup.Request, completionHandler: @escaping (Bool) -> ()) {
        let dispatchGroup = DispatchGroup()
        var requestStatus = true
        dispatchGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async(group: dispatchGroup) {
            self.fetchBookMetaData(for: request.book) { status in
                requestStatus = requestStatus && status
                if requestStatus {
                    self.fetchTocXhtml(for: request.book) { status in
                        requestStatus = requestStatus && status
                        if requestStatus {
                            self.fetchPackageOpf(for: request.book) { status in
                                requestStatus = requestStatus && status
                                self.copyTocPackageOpfFiles(for: request.book) {
                                    dispatchGroup.leave()
                                }
                            }
                        } else {
                            dispatchGroup.leave()
                        }
                    }
                }
                else {
                    dispatchGroup.leave()
                }
            }
        }

        dispatchGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async(group: dispatchGroup) {
            self.fetchBookProfile(for: request.book) { status in
                requestStatus = requestStatus && status
                if requestStatus {
                    self.fetchTableOfContents(for: request.book) { status in
                        requestStatus = requestStatus && status
                        if requestStatus {
                            self.fetchManifest(for: request.book) { status in
                                requestStatus = requestStatus && status
                                dispatchGroup.leave()
                            }
                        }
                        else {
                            dispatchGroup.leave()
                        }
                    }
                } else {
                    dispatchGroup.leave()
                }
            }
        }
        dispatchGroup.notify(queue: .main) {
            completionHandler(requestStatus)
        }
    }
    
    func setupSupplementaryBookData(request: BookSetup.Request) {
        DispatchQueue.global(qos: .default).async {
            self.fetchBookModules(for: request.book)
            self.fetchAssignments(for: request.book)
            self.fetchMLGlossary(for: request.book)
            self.fetchPrompts(book: request.book)
        }
    }
    
    func setupBook(request: BookSetup.Request, completionHandler: @escaping (Bool) -> ()) {
        self.setupManifest(request: request, completionHandler: completionHandler)
        self.setupSupplementaryBookData(request: request)
    }
    
    func fetchBookProfile(for book: Book, completionHandler: @escaping (Bool) -> ()) {

        if let _ = book.bookProfile {
            completionHandler(true)
        }
        else if !AppDelegate.isReachable(){
            let bookProfileResource = OfflineResource(contentType: .bookProfile, bookId: book.contextId(), filename: "bookProfile")
            FileSystemManager.shared.fetchContent(from: bookProfileResource) { (status, data) in
                if let _bookProfile = BookProfile(data: data ?? Data(capacity: 1)) {
                    book.bookProfile = _bookProfile
                    if self.save(book: book) {
                        completionHandler(true)
                        return
                    }
                } else {
                    completionHandler(false)
                }
            }
        } else {
            let profileRequest = BookProfileWorker.Request(bookId: book.contextId(), environment: self.environment)
            self.bookProfileWorker.fetchProfile(request: profileRequest) { response in
                switch response.result {
                case .success(let bookProfile):
                    DispatchQueue.main.async {
                        book.bookProfile = bookProfile
                        _ = self.save(book: book)
                        completionHandler(true)
                    }
                case .failure(let error):
                    ConsoleLog.error("Failed to retrieve book profile for: (\(book.contextId())), Error: \(error)")
                    completionHandler(false)
                }
            }
        }
    }
    
    //MARK:- Private methods
    fileprivate func copyTocPackageOpfFiles(for book: Book, completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async {
            let bookId = book.contextId()
            let offlineManifests = self.manifestStore.fetch(bookId: bookId)
            let downloadedManifestItems = offlineManifests.filter { $0.isDownloaded }
            if downloadedManifestItems.count > 0 {
                let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                for manifestItem in downloadedManifestItems {
                    let tocResource = OfflineResource(contentType: .toc, bookId: bookId, filename: "toc.xhtml")
                    self.fileSystemManager.fetchContent(from: tocResource) { (status, data) in
                        if let _data = data {
                            do {
                                let destinationPath = cachesDirectory.appendingPathComponent("\(manifestItem.assetId)/OPS/xhtml/toc.xhtml")
                                ConsoleLog.debug("Destination path to copy toc.xhtml file ===> \(destinationPath)")
                                try _data.write(to: destinationPath, options: [.atomic])
                            } catch let error {
                                ConsoleLog.error("Failed to copy toc.xhtml to existing downloaded folder for asset: \(manifestItem.assetId)\n Error ==> \(error)")
                            }
                        }
                    }

                    let packageOpfResource = OfflineResource(contentType: .opf, bookId: bookId, filename: "package.opf")
                    self.fileSystemManager.fetchContent(from: packageOpfResource) { (status, data) in
                        if let _data = data {
                            do {
                                let destinationPath = cachesDirectory.appendingPathComponent("\(manifestItem.assetId)/OPS/package.opf")
                                ConsoleLog.debug("Destination path to copy package.opf file ===> \(destinationPath)")
                                try _data.write(to: destinationPath, options: [.atomic])
                            } catch let error {
                                ConsoleLog.error("Failed to copy package.opf to existing downloaded folder for asset: \(manifestItem.assetId)\n Error ==> \(error)")
                            }
                        }
                    }
                }
            }

            completionHandler()
        }
    }

    fileprivate func fetchTocXhtml(for book: Book, completionHandler: @escaping (Bool) -> ()) {
        guard AppDelegate.isReachable() else {
            ConsoleLog.debug("Device is offline, cancelling toc.html request!")
            completionHandler(true)
            return
        }

        ConsoleLog.debug("Requesting toc.xhtml")
        if let tocUrls = book.bookMetaData?.toc.filter({ $0.contains("toc.xhtml") }), tocUrls.count > 0 {
            let _tocUrl = tocUrls[0]
            let bookId = book.contextId()
            self.tocXhtmlWorker.fetchTocXhtml(from: _tocUrl, bookId: bookId) { (status) in
                completionHandler(status)
            }
        } else {
            ConsoleLog.error("********* Unable to find a valid toc.xhtml URL!!! *********")
            completionHandler(false)
        }
    }

    fileprivate func fetchPackageOpf(for book: Book, completionHandler: @escaping (Bool) -> ()) {
        guard AppDelegate.isReachable() else {
            ConsoleLog.debug("Device is offline, cancelling package.opf request!")
            completionHandler(true)
            return
        }

        ConsoleLog.debug("Requesting package.opf")
        if let tocUrls = book.bookMetaData?.toc.filter({ $0.contains(".opf") }), tocUrls.count > 0 {
            let _packageOpfUrl = tocUrls[0]
            let bookId = book.contextId()
            packageOpfWorker.fetchPackageOpf(from: _packageOpfUrl, bookId: bookId) { (status) in
                completionHandler(status)
            }
        } else {
            ConsoleLog.error("********* Unable to find a valid package.opf URL!!! *********")
            completionHandler(false)
        }
    }

    fileprivate func fetchTableOfContents(for book: Book, completionHandler: @escaping (Bool) -> ()) {
        let bookId = book.contextId()
        let resource = OfflineResource(contentType: .navigation, bookId: bookId, filename: bookId)
        if book.totalPages > 0 {
            ConsoleLog.debug("Using local data")
            completionHandler(true)
        } else if !AppDelegate.isReachable() && self.fileSystemManager.isResourceReachable(resource: resource) {
            FileSystemManager.shared.fetchContent(from: resource) { (status, data) in
                var json :[String: Any]?
                do {
                    json = try JSONSerialization.jsonObject(with: data ?? Data(capacity: 1), options: []) as? [String : Any]
                } catch {
                    json = nil
                }
                if let _json = json, let pageData = _json["pageList"] as? [String: Any],
                    let totalPages = pageData["totalPages"] as? Int,
                    let toc = _json["toc"] as? [[String: Any]] {
                    book.totalPages = totalPages
                    if self.save(book: book) {
                        completionHandler(true)
                        return
                    }
                }  else {
                    completionHandler(false)
                }
            }
        } else {
            ConsoleLog.debug("Requesting remote data")
            DispatchQueue.main.async {
                self.tocWorker?.releaseWebView()
                self.tocWorker.fetch(book: book) { (data) in
                    do {
                        if let _json = data {
                            //ConsoleLog.debug("Converting to data ===> \n \(_json.description)")
                            let _data = try JSONSerialization.data(withJSONObject: _json, options: JSONSerialization.WritingOptions(rawValue: 0))
                            self.fileSystemManager.saveContent(_data, to: resource) { status in
                                ConsoleLog.debug("Offline content for book:\(book.contextId()) - save status: \(status)")
                            }
                        }
                    } catch let error {
                        ConsoleLog.error("Unable to convert dictionary to data object: Error ===> \(error)")
                    }

                    if let totalPages = self.saveTableOfContents(for: book, json: data) {
                        book.totalPages = totalPages
                        if self.save(book: book) {
                            completionHandler(true)
                            return
                        }
                    }
                    //If TOC fetch/save failed, return failure status
                    completionHandler(false)
                }
            }
        }
    }
    
    fileprivate func saveTableOfContents(for book: Book, json: [String: Any]?) -> Int? {
        guard let data = json, let pageData = data["pageList"] as? [String: Any],
            let totalPages = pageData["totalPages"] as? Int,
            let toc = data["toc"] as? [[String: Any]]  else {
                return nil
        }
        
        ConsoleLog.debug("Saving TOC data")
        let bookId = book.contextId()
        self.pageDataStore.reset()
        _ = self.pageDataStore.persist(items: toc, bookId: bookId, parentUrl: nil)
        if !self.pageDataStore.saveAllModels(bookId: bookId) {
            ConsoleLog.error("Failed to save page data store models!!")
        }
        
        ConsoleLog.debug("Looking for Custom Basket data")
        guard let customBasket = data["customBasket"] as? [String: Any],
            let customPlayListTree = customBasket["_customPlayListTree"] as? [String: Any],
            let customBasketLearningObj = customPlayListTree["learning-objectives"] as? [String: Any],
            let customBasketTree = customBasketLearningObj["los"] as? [[String: Any]] else {
                ConsoleLog.debug("Custom Basket is unavailable!!")
                return totalPages
        }
        
        self.customBasketDataStore = CustomBasketDataStore(bookId: bookId, feature: "custombasket")
        self.customBasketDataStore.pageNumberProvider.reset()
        _ = self.customBasketDataStore.persist(items: customBasketTree, bookId: bookId, parentUrl: nil)
        self.customBasketDataStore.saveAllModels(bookId)
        
        return totalPages
    }
    
    fileprivate func fetchManifest(for book: Book, completionHandler: @escaping (Bool) -> ()) {
        DispatchQueue.main.async {
            if !AppDelegate.isReachable() {
                ConsoleLog.debug("Using local data")
                completionHandler(true)
            }
            else {
                ConsoleLog.debug("Requesting remote data")
                self.manifestWorker.fetchManifestFromS3(request: OfflineManifestWorker.Request(bookId: book.contextId(), environment: self.environment)) { response in
                    switch response.result {
                    case .success(let items):
                        DispatchQueue.main.async {
                            self.manifestSuccessHandler(for: book, manifestItems: items, completionHandler: completionHandler)
                        }

                    case .failure:
                        ConsoleLog.debug("Manifest not available in S3 bucket!! Now go fetch from NEXTEXT Service")
                        self.fetchManifestFromNextext(for: book, completionHandler: completionHandler)
                    }
                }
            }
        }
    }
    
    fileprivate func fetchManifestFromNextext(for book: Book, completionHandler: @escaping (Bool) -> ()) {
        self.manifestWorker.fetchManifestFromNextext(request: OfflineManifestWorker.Request(bookId: book.contextId(), environment: StoredProperties.Common.environment)) { response in
            switch response.result {
            case .success(let items):
                DispatchQueue.main.async {
                    self.manifestSuccessHandler(for: book, manifestItems: items, completionHandler: completionHandler)
                }
                
            case .failure:
                ConsoleLog.debug("Failed to retrieve the manifest from NEXTEXT service!")
                completionHandler(false)
            }
        }
    }
    
    fileprivate func manifestSuccessHandler(for book: Book, manifestItems: [JSON], completionHandler: @escaping (Bool) -> ()) {
        guard let bookProfile = book.bookProfile else {
            ConsoleLog.error("BookProfile unavailable, skipping manifest persistence!!!")
            completionHandler(false)
            return
        }
        
        if bookProfile.offlineAccessType == .chunkedEpub {
            //Fetch TOC level one pages only if the book is chunckedEpub
            let chapterLevelOnePages = self.pageDataStore.fetchChapterLevelOnePages(bookId: book.contextId())
            let offlineBookManifest = self.manifestStore.persist(items: manifestItems, book: book, tocLevelOnePages: chapterLevelOnePages)
            if !offlineBookManifest.isEmpty {
                self.pageDataStore.updateAssetId(bookId: book.contextId(), manifest: offlineBookManifest)
            }
        } else {
            //Updating assetId for entireEpub books
            let offlineBookManifest = self.manifestStore.persist(items: manifestItems, book: book, tocLevelOnePages: nil)
            if !offlineBookManifest.isEmpty {
                self.pageDataStore.updateAssetId(offlineBookManifest[0].assetId, forBookId: book.contextId())
            }
        }
        completionHandler(true)
    }
    
    fileprivate func fetchMLGlossary(for book: Book) {
        // Check to see if we have the worker.
        guard let _ = self.mlgWorker else {
            book.hasMLG = false
            _ = self.save(book: book)
            
            self.fetchGlossary(for: book)
            return
        }
        
        // Fetch from the service and store in the database
        let mlgDataStore = MLGlossaryDataStore(bookId: book.contextId())
        mlgDataStore.getMLGCount(completionHandler: { mlgCount in
            book.hasMLG = mlgCount > 0 ? true : false
            if !book.hasMLG {
                let glossaryUrl = book.onlineBaseUrl + "OPS/xhtml/glossary.xhtml"
                self.mlgWorker.fetch(bookId: book.contextId(), glossaryUrl: glossaryUrl, completionHandler: { data in
                    if let _data = data {
                        mlgDataStore.save(data: _data) { terms in
                            book.hasMLG = !terms.isEmpty
                            _ = self.save(book: book)
                        }
                    }
                    else {
                        book.hasMLG = false
                        // Chained the regular glossary request with MultiLingualGlossary. MLG is given priority over regular glossary for a book. If no MLG then go fetch Glossary to display in sidebar
                        self.fetchGlossary(for: book)
                        _ = self.save(book: book)
                    }
                })
            }
        })
    }
    
    fileprivate func fetchGlossary(for book: Book) {
        glossaryWorker.fetchGlossaryFor(bookId: book.contextId(), bookindexId: book.indexId) { (items) in
            if let glossaryItems = items, !glossaryItems.isEmpty {
                book.hasMLG = false
            }
        }
    }
    
    fileprivate func fetchBookModules(for book: Book) {
        if let _ = book.bookModules {
            return
        }

        let modulesRequest = BookModulesWorker.Request(bookId: book.contextId(), environment: self.environment)
        bookModulesWorker.fetchModules(request: modulesRequest) { response in
            switch response.result {
            case .success(let modules):
                DispatchQueue.main.async {
                    book.bookModules = modules
                    _ = self.save(book: book)
                }

            case .failure(let error):
                ConsoleLog.error("Failed to fetch book modules. Error: \(error)")
            }
        }
    }

    fileprivate func fetchBookMetaData(for book: Book, completionHandler: @escaping (Bool) -> ()) {
        guard AppDelegate.isReachable() else {
            completionHandler(true)
            return
        }

        let metaDataRequest = BookMetaDataWorker.Request(bookId: book.contextId(), environment: self.environment)
        bookMetaDataWorker.fetchMetaData(request: metaDataRequest) { response in
            switch response.result {
            case .success(let metaData):
                DispatchQueue.main.async {
                    book.bookMetaData = metaData
                    _ = self.save(book: book)
                    completionHandler(true)
                }

            case .failure(let error):
                ConsoleLog.error("Failed to fetch book metaData. Error: \(error)")
                completionHandler(false)
            }
        }
    }
    
    fileprivate func fetchAssignments(for book: Book) {
        if let _assignmentManager = self.assignmentManager {
            _assignmentManager.fetchAssignments(forBookId: book.contextId())
        } else {
            ConsoleLog.error("Unable to fetch assignments, Assignment Manager not configured!!!")
        }
    }
    
    fileprivate func fetchPrompts(book: Book) {
        promptStore?.fetch(bookId: book.contextId()) { promptsArray in
            if promptsArray.isEmpty {
                RRNoteBookPromptManager.sharedInstance().fetchPrompts(forBook: book.contextId()) { (result, error: Error?) in
                    guard let promptModels = result as? [RRNoteBookPrompt] else { return }
                    ConsoleLog.debug("Prompt count for book ===> \(promptModels.count)")
                    if !promptModels.isEmpty {
                        DispatchQueue.main.async {
                            for prompt in promptModels {
                                self.buildEmptyNote(fromPrompt: prompt)
                            }
                            book.notesBuiltForPrompts = true
                            _ = self.save(book: book)
                        }
                    }
                }
            } else if !(book.notesBuiltForPrompts){
                DispatchQueue.main.async {
                    for prompt in promptsArray {
                        self.buildEmptyNote(fromPrompt: prompt)
                    }
                    book.notesBuiltForPrompts = true
                    _ = self.save(book: book)
                }
            }
        }
    }
    
    fileprivate func buildEmptyNote(fromPrompt prompt: RRNoteBookPrompt) {
        let pageId = RRNoteBookUtilities.pageId(forPageContext: prompt.uri, withBookContext: SessionProperties.currentBook.contextId())
        let usedId = SessionProperties.userSession?.user.uuid
        let promptAnswerID = RRNoteBookUtilities.promptAnswerId(forPromptQuestionId: prompt.promptId, withPageId: pageId, withUserId: usedId)
        let document = NotebookDataManager.sharedInstance.database?.existingDocument(withID: promptAnswerID!)
        RRNoteBookNoteManager.sharedInstance().validate(document)
        if document == nil || (document?.isDeleted)! {
            RRNoteBookNoteManager.sharedInstance().addBlankNote(forPage: prompt.uri, withType: "p", withParentId: prompt.promptId)
        }
    }
    
    fileprivate func save(book: Book) -> Bool {
        do {
            try book.save()
        } catch let error as NSError {
            ConsoleLog.error("Failed to save book: (\(book.contextId())), Error: \(error)")
            return false
        }
        return true
    }
}
