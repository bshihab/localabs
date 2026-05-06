import Foundation

/// Streams a .gguf file to disk with byte-accurate progress and cancel support.
final class ModelDownloader: NSObject, URLSessionDownloadDelegate {
    struct Progress {
        let fractionCompleted: Double
        let bytesWritten: Int64
        let bytesExpected: Int64
    }

    var onProgress: ((Progress) -> Void)?
    private var continuation: CheckedContinuation<Void, Error>?
    private var destinationURL: URL?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?

    func download(from url: URL, to destination: URL) async throws {
        self.destinationURL = destination

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
                self.session = session
                let task = session.downloadTask(with: url)
                self.task = task
                task.resume()
            }
        } onCancel: { [weak self] in
            self?.cancel()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress?(Progress(
            fractionCompleted: Double(totalBytesWritten) / Double(totalBytesExpectedToWrite),
            bytesWritten: totalBytesWritten,
            bytesExpected: totalBytesExpectedToWrite
        ))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let dest = destinationURL else { return }
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
        } catch {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer {
            self.session?.invalidateAndCancel()
            self.session = nil
            self.task = nil
        }
        if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
        continuation = nil
    }
}
