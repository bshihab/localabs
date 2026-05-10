import Foundation
import UIKit

/// Streams a .gguf file to disk via a `URLSessionConfiguration.background`
/// session — survives app backgrounding, suspension, and even hard-kill.
/// iOS owns the transfer once it's started; if the app gets killed, the
/// download keeps going and iOS relaunches the app to deliver the result.
///
/// One delegate handles all progress + completion + foreground-relaunch
/// callbacks. It's designed as a singleton because background sessions
/// must use a stable session identifier for iOS to find them again on
/// relaunch — instantiating multiple URLSessions with the same identifier
/// is undefined behavior.
final class ModelDownloader: NSObject, URLSessionDownloadDelegate {

    static let shared = ModelDownloader()

    /// Stable identifier so iOS can route relaunch events back to us.
    private static let sessionIdentifier = "com.bilalshihab.MedGemma.modelDownloads"

    struct Progress {
        let fractionCompleted: Double
        let bytesWritten: Int64
        let bytesExpected: Int64
    }

    var onProgress: ((Progress) -> Void)?

    /// Held by the AppDelegate when iOS calls
    /// `application(_:handleEventsForBackgroundURLSession:completionHandler:)`.
    /// We invoke it on the main queue once `urlSessionDidFinishEvents` fires
    /// so iOS knows we're done processing the relaunch event.
    var backgroundCompletionHandler: (() -> Void)?

    private var continuation: CheckedContinuation<Void, Error>?
    private var destinationURL: URL?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?

    private override init() {
        super.init()
    }

    private func makeSession() -> URLSession {
        if let session { return session }
        // `.background(withIdentifier:)` is what makes the transfer
        // resilient: iOS itself manages the connection and continues
        // the download even when our process is suspended or killed.
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.isDiscretionary = false       // run regardless of power/network state
        config.sessionSendsLaunchEvents = true // relaunch app on completion
        config.allowsCellularAccess = true
        let session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        self.session = session
        return session
    }

    func download(from url: URL, to destination: URL) async throws {
        self.destinationURL = destination

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let task = makeSession().downloadTask(with: url)
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

    // MARK: - URLSessionDownloadDelegate

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
        // The temp file iOS hands us is deleted the moment this delegate
        // returns, so we must move it synchronously here.
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
        if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
        continuation = nil
        self.task = nil
        // Don't invalidate the session — for background sessions iOS owns
        // the lifetime, and invalidating mid-flight breaks the
        // didFinishEvents callback that tells the OS we're done.
    }

    /// Called when iOS has finished delivering all queued events for the
    /// background session — at this point we tell iOS we're done with
    /// the relaunch so it can re-suspend us if appropriate.
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { [weak self] in
            self?.backgroundCompletionHandler?()
            self?.backgroundCompletionHandler = nil
        }
    }
}
