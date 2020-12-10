//
//  BookDownloadOperation.swift

import ZipArchive

class BookDownloadOperation: DownloadOperation {

    //MARK:- Properties
    fileprivate var downloadableItem: DownloadableItem
    
    fileprivate let offlineContentDirectoryURL: URL = {
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }()
    

    //MARK:- Lifecycle Methods
    init(session: URLSession, urlRequest: URLRequest, downloadableItem: DownloadableItem) {
        self.downloadableItem = downloadableItem
        super.init(session: session, urlRequest: urlRequest)
    }
    
    override func main() {
        task.resume()
        self.status = .inProgress
    }


    //MARK:- Session Download Delegate Methods
    override func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {

        if totalBytesExpectedToWrite != NSURLSessionTransferSizeUnknown && totalBytesWritten > 0 {
            let progressInPercentage = floor((Double(totalBytesWritten - 1) / Double(totalBytesExpectedToWrite)) * 100.0)
            if progress != progressInPercentage {
                progress = progressInPercentage

                //ConsoleLog.debug("Total: \(totalBytesExpectedToWrite) : Downloaded: \(totalBytesWritten) ===> Progress: \(progressInPercentage)")
                delegate?.operation(taskIdentifier: downloadTask.taskIdentifier, progressInPercentage: progressInPercentage)
            }
        }
        else {
            ConsoleLog.error("Unknown file download size, cannot provide download progress update!!!")
        }
    }
    
    override func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {

        //ConsoleLog.debug("didFinishDownloadingTo location: \(location.absoluteString)")
        if let file = downloadTask.originalRequest?.url?.lastPathComponent {
            let destination = offlineContentDirectoryURL.appendingPathComponent(file)
            //Remove if the file already exists
            if !destination.path.isEmpty && FileManager.default.fileExists(atPath: destination.path) {
                do {
                    try FileManager.default.removeItem(at: destination)
                    //ConsoleLog.debug("Removed existing file from location: \(destinationURL.absoluteString)")
                }
                catch _ as NSError {
                    ConsoleLog.error("Failed to remove downloaded content from: \(destination.absoluteString), before moving newly downloaded content!!")
                    /* No action needed */
                }
            }

            do {
                //Move and rename the temp file to zip file
                try FileManager.default.copyItem(at: location, to: destination)

                //Unarchive the file for application use
                let unzipFolderUrl = offlineContentDirectoryURL.appendingPathComponent(downloadableItem.assetId)
                try SSZipArchive.unzipFile(atPath: destination.path, toDestination: unzipFolderUrl.path, overwrite: true, password: nil)
                try FileManager.default.removeItem(at: destination) //Remove zip file


                let fs = FileSystemManager.shared
                let tocResource = OfflineResource(contentType: .toc, bookId: downloadableItem.bookId, filename: "toc.xhtml")
                fs.fetchContent(from: tocResource) { (status, data) in
                    if let _data = data {
                        do {
                            let destinationPath = unzipFolderUrl.appendingPathComponent("OPS/xhtml/toc.xhtml")
                            try _data.write(to: destinationPath, options: [.atomic])
                        } catch let error {
                            ConsoleLog.error("Failed to copy toc.xhtml to chunked folder for asset: \(self.downloadableItem)\n Error ==> \(error)")
                        }
                    }
                }

                let packageOpfResource = OfflineResource(contentType: .opf, bookId: downloadableItem.bookId, filename: "package.opf")
                fs.fetchContent(from: packageOpfResource) { (status, data) in
                    if let _data = data {
                        do {
                            let destinationPath = unzipFolderUrl.appendingPathComponent("OPS/package.opf")
                            try _data.write(to: destinationPath, options: [.atomic])
                        } catch let error {
                            ConsoleLog.error("Failed to copy package.opf to chunked folder for asset: \(self.downloadableItem)\n Error ==> \(error)")
                        }
                    }
                }

                // extract glossary media content
                let isGlossaryContent = fs.isResourceReachable(for: unzipFolderUrl.appendingPathComponent("OPS/xhtml/glossary.xhtml"))
                // Audio files are available in different folder names, looking at different folders for glossary media files
                var isGlossaryAudioContentPresent = false
                var audioSourceFolder = ""
                let supportedAudioFolders = ["OPS/audio", "OPS/audios"]
                for audioFolder in supportedAudioFolders where fs.isResourceReachable(for: unzipFolderUrl.appendingPathComponent(audioFolder)) {
                    isGlossaryAudioContentPresent = true
                    audioSourceFolder = audioFolder
                    break
                }

                if isGlossaryContent && isGlossaryAudioContentPresent {
                    let glossaryResource = OfflineResource(contentType: .glossary, bookId: downloadableItem.bookId, filename: "")
                    let audioSourceFolderUrl = unzipFolderUrl.appendingPathComponent("\(audioSourceFolder)/")
                    if fs.isResourceReachable(for: glossaryResource.folderPath) {
                        fs.copyDirectoryContent(from: audioSourceFolderUrl, to: glossaryResource.folderPath) { (isFinished) in
                            if isFinished {
                                ConsoleLog.error("Glossary audio copyied into the offline-content")
                            } else {
                                ConsoleLog.error("Unable to copy Glossary audio into the offline-content")
                            }
                        }
                    } else {

                        fs.copyContent(from: audioSourceFolderUrl, to: glossaryResource.folderPath) { (isFinished) in
                            if isFinished {
                                 ConsoleLog.error("Glossary audio copyied into the offline-content")
                            } else {
                                 ConsoleLog.error("Unable to copy Glossary audio into the offline-content")
                            }
                        }
                    }
                }

                delegate?.operation(taskIdentifier: downloadTask.taskIdentifier, didFinishDownloadTo: unzipFolderUrl)
            }
            catch let error as NSError {
                ConsoleLog.error("Failed to unarchive downloaded content @ \(destination.absoluteString), \nError ===> \(error.description)")
                delegate?.operation(taskIdentifier: downloadTask.taskIdentifier, didFinishDownloadWith: error)
            }
        }

        //At the end of download, must call completeOperation()
        self.completeOperation()
        self.status = .completed
    }
}
