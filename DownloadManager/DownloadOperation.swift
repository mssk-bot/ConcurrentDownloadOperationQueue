//
//  DownloadOperation.swift

protocol DownloadOperationDelegate: class {
    func operation(taskIdentifier: Int, progressInPercentage: Double)
    func operation(taskIdentifier: Int, didFinishDownloadTo location: URL)
    func operation(taskIdentifier: Int, didFinishDownloadWith error: Error?)
}

class DownloadOperation: Operation {

    //MARK: Base class Properties
    override var isAsynchronous: Bool { return true }
    
    fileprivate var _executing = false
    override var isExecuting: Bool {
        get {
            return _executing
        }
        set {
            self.willChangeValue(forKey: "isExecuting")
            _executing = newValue
            self.didChangeValue(forKey: "isExecuting")
        }
    }
    
    fileprivate var _finished = false
    override var isFinished: Bool {
        get {
            return _finished
        }
        set {
            self.willChangeValue(forKey: "isFinished")
            _finished = newValue
            self.didChangeValue(forKey: "isFinished")
        }
    }
    
    //MARK: Custom Properties
    var urlRequest: URLRequest
    var task: URLSessionDownloadTask
    
    var needsResume = false /* To be overridden by sub-classes to enable resume operation */
    var contentToResume: Data?
    
    var status: DownloadStatus = .notStarted
    var progress: Double = 0.0
    weak var delegate: DownloadOperationDelegate?

    //MARK: Lifecycle Methods
    init(session: URLSession, urlRequest: URLRequest) {
        self.urlRequest = urlRequest
        self.task = session.downloadTask(with: urlRequest)
    }
    
    //MARK: Operation Methods
    override func start() {
        if isCancelled {
            isFinished = true
            return
        }

        isExecuting = true
        main()
    }
    
    override func cancel() {
        ConsoleLog.debug("Called")
        if needsResume {
            self.task.cancel { [weak self] data in
                guard let `self` = self, let resumeData = data else { return }
                self.contentToResume = resumeData
                self.status = .paused
            }
        }
        else {
            task.cancel()
            self.status = .completed
        }
        
        super.cancel()
        self.completeOperation()
    }
    
    func completeOperation() {
        if isExecuting {
            isExecuting = false
            isFinished = true
        }
    }
}


//MARK:- Download Session Delegate Extension
extension DownloadOperation: URLSessionDownloadDelegate {

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        //ConsoleLog.debug("Called!")
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didResumeAtOffset fileOffset: Int64, expectedTotalBytes: Int64) {
        //ConsoleLog.debug("Called!")
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        //ConsoleLog.debug("Called!")
    }
}
