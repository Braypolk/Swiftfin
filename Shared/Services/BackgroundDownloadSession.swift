//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2025 Jellyfin & Jellyfin Contributors
//

import Combine
import Factory
import Foundation
import Logging

// MARK: - BackgroundDownloadSession

/// Singleton service managing background URLSession for downloads.
/// Supports pause/resume with resume data and continues downloads when app is backgrounded.
class BackgroundDownloadSession: NSObject, ObservableObject {

    // MARK: - Singleton

    static let shared = BackgroundDownloadSession()

    // MARK: - Constants

    static let identifier = "com.jellyfin.swiftfin.downloads"

    // MARK: - Properties

    private let logger = Logger.swiftfin()

    /// The background URLSession
    private(set) var session: URLSession!

    /// Completion handler stored from background launch
    private var backgroundCompletionHandler: (() -> Void)?

    /// Active download tasks mapped by item ID
    private var activeDownloads: [String: URLSessionDownloadTask] = [:]

    /// Mapping from URLSession task identifier to item ID
    private var taskToItemID: [Int: String] = [:]

    /// Progress callbacks per item ID
    private var progressCallbacks: [String: (Double, Int64, Int64) -> Void] = [:]

    /// Completion callbacks per item ID
    private var completionCallbacks: [String: (Result<URL, Error>) -> Void] = [:]

    /// Resume data callbacks per item ID (called when download is cancelled with resume data)
    private var resumeDataCallbacks: [String: (Data?) -> Void] = [:]

    /// Published progress updates
    @Published
    private(set) var downloadProgress: [String: Double] = [:]

    /// Published bytes downloaded
    @Published
    private(set) var bytesDownloaded: [String: Int64] = [:]

    /// Published total bytes
    @Published
    private(set) var totalBytes: [String: Int64] = [:]

    // MARK: - Initialization

    override private init() {
        super.init()

        let configuration = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.allowsCellularAccess = true

        // Create session with self as delegate
        session = URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: nil
        )

        // Reconnect to any existing tasks from previous session
        reconnectToExistingTasks()

        logger.info("BackgroundDownloadSession initialized with identifier: \(Self.identifier)")
    }

    // MARK: - Public Methods

    /// Start a download for an item
    /// - Parameters:
    ///   - url: The URL to download from
    ///   - itemID: The unique item ID
    ///   - headers: Optional HTTP headers (e.g., authorization)
    ///   - progress: Progress callback (progress, bytesDownloaded, totalBytes)
    ///   - completion: Completion callback with downloaded file URL or error
    /// - Returns: The URLSessionDownloadTask
    @discardableResult
    func startDownload(
        url: URL,
        itemID: String,
        headers: [String: String]? = nil,
        progress: @escaping (Double, Int64, Int64) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) -> URLSessionDownloadTask {
        var request = URLRequest(url: url)
        headers?.forEach { request.setValue($1, forHTTPHeaderField: $0) }

        let task = session.downloadTask(with: request)
        activeDownloads[itemID] = task
        taskToItemID[task.taskIdentifier] = itemID
        progressCallbacks[itemID] = progress
        completionCallbacks[itemID] = completion

        task.resume()
        logger.info("Started download for item \(itemID) from \(url.absoluteString)")

        return task
    }

    /// Resume a download using resume data
    /// - Parameters:
    ///   - resumeData: The resume data from a previous download
    ///   - itemID: The unique item ID
    ///   - progress: Progress callback
    ///   - completion: Completion callback
    /// - Returns: The URLSessionDownloadTask
    @discardableResult
    func resumeDownload(
        resumeData: Data,
        itemID: String,
        progress: @escaping (Double, Int64, Int64) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) -> URLSessionDownloadTask {
        let task = session.downloadTask(withResumeData: resumeData)
        activeDownloads[itemID] = task
        taskToItemID[task.taskIdentifier] = itemID
        progressCallbacks[itemID] = progress
        completionCallbacks[itemID] = completion

        task.resume()
        logger.info("Resumed download for item \(itemID)")

        return task
    }

    /// Pause a download and get resume data
    /// - Parameters:
    ///   - itemID: The item ID to pause
    ///   - completion: Callback with resume data (nil if not resumable)
    func pauseDownload(itemID: String, completion: @escaping (Data?) -> Void) {
        guard let task = activeDownloads[itemID] else {
            logger.warning("No active download found for item \(itemID)")
            completion(nil)
            return
        }

        resumeDataCallbacks[itemID] = completion

        task.cancel { [weak self] resumeData in
            DispatchQueue.main.async {
                self?.resumeDataCallbacks[itemID]?(resumeData)
                self?.resumeDataCallbacks.removeValue(forKey: itemID)
                self?.cleanupTask(itemID: itemID)

                if resumeData != nil {
                    self?.logger.info("Paused download for item \(itemID) with resume data")
                } else {
                    self?.logger.warning("Paused download for item \(itemID) without resume data")
                }
            }
        }
    }

    /// Cancel a download without resume data
    /// - Parameter itemID: The item ID to cancel
    func cancelDownload(itemID: String) {
        guard let task = activeDownloads[itemID] else {
            logger.warning("No active download found for item \(itemID)")
            return
        }

        task.cancel()
        cleanupTask(itemID: itemID)
        logger.info("Cancelled download for item \(itemID)")
    }

    /// Delete the temporary file associated with resume data
    func deleteResumeData(_ resumeData: Data) {
        // Create a task with the resume data and immediately cancel it.
        // This triggers the system to clean up the temporary file.
        let task = session.downloadTask(withResumeData: resumeData)
        task.cancel()
    }

    /// Get the download task for an item
    /// - Parameter itemID: The item ID
    /// - Returns: The active download task, if any
    func task(for itemID: String) -> URLSessionDownloadTask? {
        activeDownloads[itemID]
    }

    /// Store completion handler from AppDelegate for background events
    func storeCompletionHandler(_ handler: @escaping () -> Void) {
        backgroundCompletionHandler = handler
        logger.info("Stored background completion handler")
    }

    // MARK: - Private Methods

    private func cleanupTask(itemID: String) {
        if let task = activeDownloads[itemID] {
            taskToItemID.removeValue(forKey: task.taskIdentifier)
        }
        activeDownloads.removeValue(forKey: itemID)
        progressCallbacks.removeValue(forKey: itemID)
        completionCallbacks.removeValue(forKey: itemID)
        downloadProgress.removeValue(forKey: itemID)
        bytesDownloaded.removeValue(forKey: itemID)
        totalBytes.removeValue(forKey: itemID)
    }

    private func reconnectToExistingTasks() {
        session.getTasksWithCompletionHandler { [weak self] _, _, downloadTasks in
            for task in downloadTasks {
                // Try to extract item ID from task description or stored mapping
                if let itemID = task.taskDescription {
                    self?.activeDownloads[itemID] = task
                    self?.taskToItemID[task.taskIdentifier] = itemID
                    self?.logger.info("Reconnected to existing download task for item \(itemID)")
                }
            }
        }
    }
}

// MARK: - URLSessionDownloadDelegate

extension BackgroundDownloadSession: URLSessionDownloadDelegate {

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let itemID = taskToItemID[downloadTask.taskIdentifier] else { return }

        let progress = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0

        DispatchQueue.main.async { [weak self] in
            self?.downloadProgress[itemID] = progress
            self?.bytesDownloaded[itemID] = totalBytesWritten
            self?.totalBytes[itemID] = totalBytesExpectedToWrite
            self?.progressCallbacks[itemID]?(progress, totalBytesWritten, totalBytesExpectedToWrite)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let itemID = taskToItemID[downloadTask.taskIdentifier] else {
            logger.warning("Received download completion for unknown task")
            return
        }

        // Get file extension from the response Content-Type header
        var fileExtension = ""
        if let response = downloadTask.response as? HTTPURLResponse,
           let contentType = response.allHeaderFields["Content-Type"] as? String
        {
            // Extract extension from MIME type (e.g., "video/mp4" -> "mp4")
            let mimeType = contentType.components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces) ?? ""
            if let subtype = mimeType.components(separatedBy: "/").last {
                // Map common video MIME subtypes to file extensions
                switch subtype.lowercased() {
                case "mp4", "x-m4v":
                    fileExtension = "mp4"
                case "x-matroska":
                    fileExtension = "mkv"
                case "webm":
                    fileExtension = "webm"
                case "quicktime":
                    fileExtension = "mov"
                case "x-msvideo":
                    fileExtension = "avi"
                default:
                    fileExtension = subtype
                }
            }
        }

        // Move file to a temporary location that won't be deleted
        let tempFileName = fileExtension.isEmpty ? UUID().uuidString : "\(UUID().uuidString).\(fileExtension)"
        let tempURL = URL.tmp.appendingPathComponent(tempFileName)
        do {
            try FileManager.default.moveItem(at: location, to: tempURL)
            DispatchQueue.main.async { [weak self] in
                self?.completionCallbacks[itemID]?(.success(tempURL))
                self?.cleanupTask(itemID: itemID)
            }
            logger.info("Download completed for item \(itemID)")
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.completionCallbacks[itemID]?(.failure(error))
                self?.cleanupTask(itemID: itemID)
            }
            logger.error("Failed to move downloaded file for item \(itemID): \(error.localizedDescription)")
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let downloadTask = task as? URLSessionDownloadTask,
              let itemID = taskToItemID[downloadTask.taskIdentifier]
        else { return }

        if let error = error {
            // Check if this is a cancellation with resume data
            let nsError = error as NSError
            if nsError.code == NSURLErrorCancelled,
               let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            {
                DispatchQueue.main.async { [weak self] in
                    self?.resumeDataCallbacks[itemID]?(resumeData)
                    self?.resumeDataCallbacks.removeValue(forKey: itemID)

                    // Also fire completion with cancellation error so any waiting continuations are resumed
                    self?.completionCallbacks[itemID]?(.failure(error))
                    self?.cleanupTask(itemID: itemID)
                }
                logger.info("Download cancelled with resume data for item \(itemID)")
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.completionCallbacks[itemID]?(.failure(error))
                    self?.cleanupTask(itemID: itemID)
                }
                logger.error("Download failed for item \(itemID): \(error.localizedDescription)")
            }
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { [weak self] in
            self?.backgroundCompletionHandler?()
            self?.backgroundCompletionHandler = nil
            self?.logger.info("Background URLSession events finished")
        }
    }
}

// MARK: - Factory Registration

extension Container {
    var backgroundDownloadSession: Factory<BackgroundDownloadSession> {
        self { BackgroundDownloadSession.shared }.shared
    }
}
