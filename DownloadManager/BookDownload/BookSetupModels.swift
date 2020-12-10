//
//  BookSetupModels.swift

struct BookSetup {
    struct Request {
        var book: Book
        var model: Bookshelf.ViewModel?

        init(book: Book, model: Bookshelf.ViewModel? = nil) {
            self.book = book
            self.model = model
        }
    }

    struct UpdateDownloadStatus {
        struct Request {
            var bookId: String
            var downloadableItem: DownloadableItem
            var isDownloaded: Bool
        }
    }
}
