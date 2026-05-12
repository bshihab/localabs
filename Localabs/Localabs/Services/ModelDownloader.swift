import Foundation
import UIKit

/// Hybrid foreground/background downloader for the .gguf model file.
///
/// - While the app is active, the transfer runs on a fast
///   `URLSessionConfiguration.default` session — gets full network
///   bandwidth, since iOS doesn't throttle foreground sessions.
/// - The moment the app enters background, we tear down the foreground
///   task with `cancel(byProducingResumeData:)` and resume the transfer
///   on a `URLSessionConfiguration.background` session, which iOS owns
///   end-to-end. The bg session is slower but survives app suspension
///   and hard-kill: iOS keeps downloading and relaunches us on
///   completion.
///
/// This keeps the normal "user watches the download finish" case fast
/// while preserving the resilience guarantees of a background session
/// when the user puts the phone down.
///
/// Singleton because background sessions must use a stable session
/// identifier — iOS routes relaunch events to the URLSession with that
/// id, and creating multiple sessions with the same id is undefined.
final class ModelDownloader: NSObject, URLSessionDownloadDelegate {

    static let shared = ModelDownloader()

    private static let sessionIdentifier = "com.bilalshihab.Localabs.modelDownloads"

    struct Progress {
        let fractionCompleted: Double
        let bytesWritten: Int64
        let bytesExpected: Int64
    }

    var onProgress: ((Progress) -> Void)?

    /// Parked by AppDelegate when iOS relaunches us to deliver background
    /// session events. Invoked from `urlSessionDidFinishEvents` so iOS
    /// knows it's safe to re-suspend us.
    var backgroundCompletionHandler: (() -> Void)?

    private var continuation: CheckedContinuation<Void, Error>?
    private var destinationURL: URL?
    private var sourceURL: URL?

    private var foregroundSession: URLSession?
    private var backgroundSession: URLSession?
    private var activeTask: URLSessionDownloadTask?
    private var activeSession: URLSession?

    private override init() {
        super.init()
        // Watch for the app being backgrounded so we can hand off the
        // in-flight transfer from the foreground session to the
        // (resilient but slow) background session.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
    }

    /// Eagerly creates the background URLSession so iOS can bind any
    /// pending background events to its delegate. Called from the
    /// AppDelegate's `handleEventsForBackgroundURLSession` hook, which
    /// fires when iOS relaunches us specifically to deliver a finished
    /// background transfer.
    func ensureBackgroundSessionReady() {
        _ = makeBackgroundSession()
    }

    // MARK: - Session factories

    private func makeForegroundSession() -> URLSession {
        if let foregroundSession { return foregroundSession }
        let config = URLSessionConfiguration.default
        config.allowsCellularAccess = true
        // Hang on through transient network drops rather than failing
        // — the model file is big enough that one Wi-Fi blip
        // shouldn't blow away the whole download.
        config.waitsForConnectivity = true
        let session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        self.foregroundSession = session
        return session
    }

    private func makeBackgroundSession() -> URLSession {
        if let backgroundSession { return backgroundSession }
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.isDiscretionary = false       // don't let iOS defer on power/network grounds
        config.sessionSendsLaunchEvents = true
        config.allowsCellularAccess = true
        let session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        self.backgroundSession = session
        return session
    }

    // MARK: - Public API

    func download(from url: URL, to destination: URL) async throws {
        self.destinationURL = destination
        self.sourceURL = url

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation

                // If the user happens to kick off the download while the
                // app is already backgrounded, skip the foreground path —
                // there's no point starting a session iOS will immediately
                // suspend.
                let startInBackground = UIApplication.shared.applicationState == .background
                let session = startInBackground ? makeBackgroundSession() : makeForegroundSession()
                let task = session.downloadTask(with: url)
                self.activeTask = task
                self.activeSession = session
                task.resume()
            }
        } onCancel: { [weak self] in
            self?.cancel()
        }
    }

    func cancel() {
        activeTask?.cancel()
        activeTask = nil
        activeSession = nil
    }

    // MARK: - Foreground → Background handoff

    @objc private func handleAppDidEnterBackground() {
        // Only swap when we have an in-flight foreground task. If we're
        // already running on the background session, leave it alone —
        // ping-ponging adds bugs for zero gain.
        guard let task = activeTask,
              let session = activeSession,
              session === foregroundSession else { return }

        // Clear our refs first so the foreground task's incoming
        // cancellation delegate callback gets ignored (the `task ===
        // activeTask` guard in didCompleteWithError below). Otherwise
        // we'd resume the continuation with NSURLErrorCancelled and the
        // outer async download() call would think the user gave up.
        activeTask = nil
        activeSession = nil

        task.cancel(byProducingResumeData: { [weak self] resumeData in
            // The resume-data callback isn't guaranteed to be called on
            // any particular queue, so hop to main.
            DispatchQueue.main.async {
                guard let self else { return }
                let bg = self.makeBackgroundSession()
                let bgTask: URLSessionDownloadTask
                if let resumeData {
                    // Picks up from the byte offset the foreground task
                    // had reached — no re-download of the bytes already
                    // on disk.
                    bgTask = bg.downloadTask(withResumeData: resumeData)
                } else if let url = self.sourceURL {
                    // Some servers don't honor range requests — fall
                    // back to starting fresh in the background session.
                    // Hugging Face does support ranges, so in practice
                    // this branch is rare.
                    bgTask = bg.downloadTask(with: url)
                } else {
                    // No URL to retry with: nothing we can do.
                    return
                }
                self.activeTask = bgTask
                self.activeSession = bg
                bgTask.resume()
            }
        })
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
        // iOS deletes the temp file the moment this delegate returns, so
        // the move has to happen synchronously here.
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
        // Ignore completions for tasks we've already swapped out — those
        // are the cancellation events from the foreground→background
        // handoff and shouldn't resolve the outer async call.
        guard task === activeTask else { return }

        if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
        continuation = nil
        self.activeTask = nil
        self.activeSession = nil
        // Don't invalidate either session — for the background one, iOS
        // owns its lifetime, and invalidating mid-flight breaks the
        // didFinishEvents callback that signals "we're done" to the OS.
    }

    /// Fires after iOS has finished delivering all queued events for the
    /// background session on relaunch. We call the parked completion
    /// handler so iOS can re-suspend us.
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { [weak self] in
            self?.backgroundCompletionHandler?()
            self?.backgroundCompletionHandler = nil
        }
    }
}
