import Foundation

/// Handles securely downloading large .gguf weights files in the background.
class ModelDownloader: NSObject, URLSessionDownloadDelegate {
    var onProgress: ((Double) -> Void)?
    var completion: ((Error?) -> Void)?
    var destinationURL: URL?
    
    func download(from url: URL, to destination: URL) async throws {
        self.destinationURL = destination
        return try await withCheckedThrowingContinuation { continuation in
            self.completion = { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
            // Use the main queue so we can safely update the UI with progress
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
            session.downloadTask(with: url).resume()
        }
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let progress = (Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) * 100
        self.onProgress?(progress)
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let dest = destinationURL else { return }
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.moveItem(at: location, to: dest)
        self.completion?(nil)
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            self.completion?(error)
        }
    }
}
