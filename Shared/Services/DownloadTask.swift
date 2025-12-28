//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2025 Jellyfin & Jellyfin Contributors
//

import Combine
import Factory
import Files
import Foundation
import Get
import JellyfinAPI
import Logging

// MARK: - DownloadTask

class DownloadTask: NSObject, ObservableObject, Identifiable {

    // MARK: - State

    enum State: Hashable {
        case pending
        case downloading(progress: Double)
        case paused
        case complete
        case error(String)
        case cancelled

        var isActive: Bool {
            switch self {
            case .downloading:
                return true
            default:
                return false
            }
        }

        var canRetry: Bool {
            switch self {
            case .error, .cancelled, .paused:
                return true
            default:
                return false
            }
        }

        var progress: Double? {
            switch self {
            case let .downloading(progress):
                return progress
            case .complete:
                return 1.0
            default:
                return nil
            }
        }
    }

    // MARK: - Properties

    private let logger = Logger.swiftfin()

    @Injected(\.currentUserSession)
    private var userSession: UserSession!

    @Published
    var state: State = .pending

    @Published
    private(set) var stage: DownloadStage = .preparing

    @Published
    private(set) var bytesDownloaded: Int64 = 0

    @Published
    private(set) var totalBytes: Int64 = 0

    private var downloadTask: Task<Void, Never>?

    /// The background download task identifier for media downloads
    private var backgroundDownloadTaskID: String?

    /// Stored resume data if download was paused
    private var resumeData: Data?

    /// The download URL for the current media (needed for resume info)
    private var currentDownloadURL: URL?

    /// The original item being downloaded
    let item: BaseItemDto

    /// The queue item representing this download
    let queueItem: DownloadQueueItem

    /// Completion handler called when download finishes
    var onComplete: ((Result<StoredDownloadItem, Error>) -> Void)?

    var id: String {
        item.id ?? queueItem.id
    }

    // MARK: - Computed Properties

    var imagesFolder: URL? {
        item.downloadFolder?.appendingPathComponent("Images")
    }

    var metadataFolder: URL? {
        item.downloadFolder?.appendingPathComponent("Metadata")
    }

    /// Relative path from downloads root to this item's folder
    var relativeFolderPath: String? {
        guard let downloadFolder = item.downloadFolder else { return nil }
        let downloadsPath = URL.downloads.path
        let itemPath = downloadFolder.path

        if itemPath.hasPrefix(downloadsPath) {
            var relativePath = String(itemPath.dropFirst(downloadsPath.count))
            if relativePath.hasPrefix("/") {
                relativePath = String(relativePath.dropFirst())
            }
            return relativePath
        }
        return nil
    }

    // MARK: - Initialization

    init(item: BaseItemDto, queueItem: DownloadQueueItem? = nil) {
        self.item = item
        self.queueItem = queueItem ?? DownloadQueueItem(from: item)
        super.init()
    }

    convenience init(item: BaseItemDto) {
        self.init(item: item, queueItem: nil)
    }

    // MARK: - Folder Management

    func createFolder() throws {
        guard let downloadFolder = item.downloadFolder else { return }
        try FileManager.default.createDirectory(at: downloadFolder, withIntermediateDirectories: true)
    }

    func deleteRootFolder() {
        guard let downloadFolder = item.downloadFolder else { return }
        try? FileManager.default.removeItem(at: downloadFolder)
    }

    // MARK: - Download Control

    func download() {
        guard !state.isActive else { return }

        let task = Task { [weak self] in
            guard let self else { return }

            await MainActor.run {
                self.state = .downloading(progress: 0)
                self.stage = .preparing
            }

            // Delete any existing partial download only if starting fresh
            if self.resumeData == nil {
                deleteRootFolder()
            }

            do {
                // Check storage space first
                if let estimatedSize = FileManager.default.estimateDownloadSize(for: item) {
                    try FileManager.default.checkSpace(requiredBytes: estimatedSize)
                }

                // Download based on whether this is metadata-only
                if queueItem.isMetadataOnly {
                    try await downloadMetadataOnly()
                } else {
                    try await downloadFull()
                }

                await MainActor.run {
                    self.state = .complete
                    self.stage = .completed
                }

                // Create StoredDownloadItem and notify completion
                let downloadedItem = createStoredDownloadItem()
                onComplete?(.success(downloadedItem))

            } catch is CancellationError {
                // If we paused, this cancellation is expected and state is already paused
                if await MainActor.run(body: { self.state == .paused }) {
                    return
                }

                await MainActor.run {
                    self.state = .cancelled
                }
                onComplete?(.failure(DownloadError.cancelled))

            } catch {
                // If the state is paused, we expect a cancellation error but should not
                // transition to .error state. The resume data handler set the state to .paused.
                if await MainActor.run(body: { self.state == .paused }) {
                    return
                }

                await MainActor.run {
                    self.state = .error(error.localizedDescription)
                }
                logger.error("Download failed for \(self.item.displayTitle): \(error.localizedDescription)")
                onComplete?(.failure(error))
            }
        }

        self.downloadTask = task
    }

    func pause() {
        if state == .downloading(progress: 0) || state.isActive {
            // Optimistically set state to paused to prevent race conditions
            state = .paused
            logger.trace("Pausing download for: \(item.displayTitle)")

            // If we have a background download task, pause with resume data
            if let taskID = backgroundDownloadTaskID {
                BackgroundDownloadSession.shared.pauseDownload(itemID: taskID) { [weak self] resumeData in
                    guard let self else { return }
                    self.handlePauseWithResumeData(resumeData)
                }
            } else {
                // For non-media downloads (images, metadata), just cancel
                downloadTask?.cancel()
            }
        }
    }

    /// Handle pause completion with optional resume data
    private func handlePauseWithResumeData(_ data: Data?) {
        self.resumeData = data
        self.state = .paused

        // Persist resume info if we have resume data
        if let data = data, let url = currentDownloadURL {
            let resumeInfo = DownloadResumeInfo(
                itemID: id,
                downloadURL: url,
                resumeData: data,
                bytesDownloaded: bytesDownloaded,
                totalBytes: totalBytes,
                pausedAt: Date()
            )
            StoredValues[.User.downloadResumeInfo(itemID: id)] = resumeInfo
            logger.info("Saved resume data for: \(item.displayTitle)")
        }

        // Persist current progress
        StoredValues[.User.downloadBytesDownloaded(itemID: id)] = bytesDownloaded
        StoredValues[.User.downloadTotalBytes(itemID: id)] = totalBytes
        StoredValues[.User.downloadState(itemID: id)] = .paused
    }

    func cancel() {
        downloadTask?.cancel()
        state = .cancelled
        deleteRootFolder()
        logger.trace("Cancelled download for: \(item.displayTitle)")
    }

    func retry() {
        guard state.canRetry else { return }
        // Clear any stored resume data since we're retrying
        resumeData = nil
        StoredValues[.User.downloadResumeInfo(itemID: id)] = nil
        download()
    }

    /// Resume download from previously stored resume data
    func resumeFromPaused() {
        // Try to load resume info from storage
        if let resumeInfo = StoredValues[.User.downloadResumeInfo(itemID: id)] {
            self.resumeData = resumeInfo.resumeData
            self.currentDownloadURL = resumeInfo.downloadURL
            self.bytesDownloaded = resumeInfo.bytesDownloaded
            self.totalBytes = resumeInfo.totalBytes
        }
        download()
    }

    // MARK: - Full Download (Media + Images + Metadata)

    private func downloadFull() async throws {
        try await downloadMedia()
        await downloadBackdropImage()
        await downloadPrimaryImage()
        await downloadLogoImage()
        saveMetadata()
    }

    // MARK: - Metadata Only Download (Images + Metadata, no media)

    private func downloadMetadataOnly() async throws {
        await downloadBackdropImage()
        await downloadPrimaryImage()
        await downloadLogoImage()
        saveMetadata()
    }

    // MARK: - Media Download

    private func downloadMedia() async throws {
        guard let downloadFolder = item.downloadFolder else { return }
        guard let itemID = item.id else { return }

        await MainActor.run {
            self.stage = .downloadingMedia(progress: 0)
        }

        // Build the download URL
        let request = Paths.getDownload(itemID: itemID)
        guard let downloadURL = userSession.client.fullURL(with: request, queryAPIKey: true) else {
            throw DownloadError.networkError("Failed to build download URL")
        }

        await MainActor.run {
            self.currentDownloadURL = downloadURL
            self.backgroundDownloadTaskID = itemID
        }

        // Build authorization headers
        var headers: [String: String] = [:]
        let accessToken = userSession.user.accessToken
        if !accessToken.isEmpty {
            headers["Authorization"] = "MediaBrowser Token=\"\(accessToken)\""
        }

        // Check if we have resume data to continue from
        if let resumeData = await MainActor.run(body: { self.resumeData }) {
            try await downloadMediaWithResumeData(resumeData, downloadFolder: downloadFolder, itemID: itemID)
        } else {
            try await downloadMediaFresh(url: downloadURL, headers: headers, downloadFolder: downloadFolder, itemID: itemID)
        }
    }

    /// Download media using resume data
    private func downloadMediaWithResumeData(_ resumeData: Data, downloadFolder: URL, itemID: String) async throws {
        // Set ID to enable pause functionality
        self.backgroundDownloadTaskID = itemID

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            BackgroundDownloadSession.shared.resumeDownload(
                resumeData: resumeData,
                itemID: itemID,
                progress: { [weak self] _, bytesDownloaded, totalBytes in
                    Task { @MainActor in
                        self?.updateProgress(bytesWritten: bytesDownloaded, totalBytes: totalBytes)
                    }
                },
                completion: { [weak self] result in
                    self?.handleMediaDownloadCompletion(result, downloadFolder: downloadFolder, continuation: continuation)
                }
            )
        }

        // Clear stored resume data after successful completion
        await MainActor.run {
            self.resumeData = nil
            StoredValues[.User.downloadResumeInfo(itemID: itemID)] = nil
        }
    }

    /// Download media from scratch
    private func downloadMediaFresh(url: URL, headers: [String: String], downloadFolder: URL, itemID: String) async throws {
        // Set ID to enable pause functionality
        self.backgroundDownloadTaskID = itemID

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            BackgroundDownloadSession.shared.startDownload(
                url: url,
                itemID: itemID,
                headers: headers,
                progress: { [weak self] _, bytesDownloaded, totalBytes in
                    Task { @MainActor in
                        self?.updateProgress(bytesWritten: bytesDownloaded, totalBytes: totalBytes)
                    }
                },
                completion: { [weak self] result in
                    self?.handleMediaDownloadCompletion(result, downloadFolder: downloadFolder, continuation: continuation)
                }
            )
        }
    }

    /// Centralized progress update logic
    private func updateProgress(bytesWritten: Int64, totalBytes: Int64) {
        // Don't update state if we are paused/cancelled/error
        // canRetry covers .paused, .cancelled, and .error
        guard !state.canRetry else { return }

        let progress = Double(bytesWritten) / Double(totalBytes)

        self.bytesDownloaded = bytesWritten
        self.totalBytes = totalBytes
        self.state = .downloading(progress: progress)

        // Only update stage progress if we are in the downloadingMedia stage
        // For images/metadata, we want to preserve the specific stage (e.g. .downloadingBackdropImage)
        if case .downloadingMedia = stage {
            self.stage = .downloadingMedia(progress: progress)
        }
    }

    /// Handle media download completion from background session
    private func handleMediaDownloadCompletion(
        _ result: Result<URL, Error>,
        downloadFolder: URL,
        continuation: CheckedContinuation<Void, Error>
    ) {
        switch result {
        case let .success(tempURL):
            do {
                try FileManager.default.createDirectory(at: downloadFolder, withIntermediateDirectories: true)

                // Determine file extension from item metadata
                guard let container = item.container, !container.isEmpty else {
                    continuation.resume(throwing: DownloadError.unknownContainer)
                    return
                }
                let mediaExtension = ".\(container)"
                let destinationURL = downloadFolder.appendingPathComponent("Media\(mediaExtension)")

                // Remove existing file if present
                try? FileManager.default.removeItem(at: destinationURL)

                try FileManager.default.moveItem(at: tempURL, to: destinationURL)
                continuation.resume()
            } catch {
                logger.error("Error moving downloaded media for: \(item.displayTitle) with error: \(error.localizedDescription)")
                continuation.resume(throwing: error)
            }
        case let .failure(error):
            // Check if this was a pause/cancel - don't treat as error
            let nsError = error as NSError
            if nsError.code == NSURLErrorCancelled {
                continuation.resume(throwing: DownloadError.cancelled)
            } else {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Image Downloads

    private func downloadBackdropImage() async {
        guard let type = item.type else { return }

        await MainActor.run {
            self.stage = .downloadingBackdropImage
        }

        let imageURL: URL

        switch type {
        case .movie, .series:
            guard let url = item.imageSource(.backdrop, maxWidth: 600).url else { return }
            imageURL = url
        case .episode:
            guard let url = item.imageSource(.primary, maxWidth: 600).url else { return }
            imageURL = url
        default:
            return
        }

        guard let response = try? await userSession.client.download(
            for: .init(url: imageURL).withResponse(URL.self),
            delegate: self
        ) else { return }

        let filename = getImageFilename(from: response, secondary: "Backdrop")
        saveImage(from: response, filename: filename)
    }

    private func downloadPrimaryImage() async {
        guard let type = item.type else { return }

        await MainActor.run {
            self.stage = .downloadingPrimaryImage
        }

        let imageURL: URL

        switch type {
        case .movie, .series, .season:
            guard let url = item.imageSource(.primary, maxWidth: 300).url else { return }
            imageURL = url
        default:
            return
        }

        guard let response = try? await userSession.client.download(
            for: .init(url: imageURL).withResponse(URL.self),
            delegate: self
        ) else { return }

        let filename = getImageFilename(from: response, secondary: "Primary")
        saveImage(from: response, filename: filename)
    }

    private func downloadLogoImage() async {
        guard let type = item.type else { return }

        await MainActor.run {
            self.stage = .downloadingLogoImage
        }

        // Logo is mainly for movies and series
        guard type == .movie || type == .series else { return }

        guard let url = item.imageSource(.logo, maxWidth: 400).url else { return }

        guard let response = try? await userSession.client.download(
            for: .init(url: url).withResponse(URL.self),
            delegate: self
        ) else { return }

        let filename = getImageFilename(from: response, secondary: "Logo")
        saveImage(from: response, filename: filename)
    }

    private func saveImage(from response: Response<URL>?, filename: String) {
        guard let response, let imagesFolder else { return }

        do {
            try FileManager.default.createDirectory(at: imagesFolder, withIntermediateDirectories: true)

            try FileManager.default.moveItem(
                at: response.value,
                to: imagesFolder.appendingPathComponent(filename)
            )
        } catch {
            logger.error("Error saving image: \(error.localizedDescription)")
        }
    }

    private func getImageFilename(from response: Response<URL>, secondary: String) -> String {
        if let suggestedFilename = response.response.suggestedFilename {
            return suggestedFilename
        } else {
            let imageExtension = response.response.mimeSubtype ?? "png"
            return "\(secondary).\(imageExtension)"
        }
    }

    // MARK: - Metadata

    func encodeMetadata() -> Data {
        try! JSONEncoder().encode(item)
    }

    private func saveMetadata() {
        guard let metadataFolder else { return }

        let jsonEncoder = JSONEncoder()
        jsonEncoder.outputFormatting = .prettyPrinted

        let itemJsonData = try! jsonEncoder.encode(item)
        let itemJson = String(data: itemJsonData, encoding: .utf8)
        let itemFileURL = metadataFolder.appendingPathComponent("Item.json")

        do {
            try FileManager.default.createDirectory(at: metadataFolder, withIntermediateDirectories: true)

            try itemJson?.write(to: itemFileURL, atomically: true, encoding: .utf8)
        } catch {
            logger.error("Error saving item metadata: \(error.localizedDescription)")
        }
    }

    // MARK: - File Access

    func getImageURL(name: String) -> URL? {
        do {
            guard let imagesFolder else { return nil }
            let images = try FileManager.default.contentsOfDirectory(atPath: imagesFolder.path)

            guard let imageFilename = images.first(where: { $0.starts(with: name) }) else { return nil }

            return imagesFolder.appendingPathComponent(imageFilename)
        } catch {
            return nil
        }
    }

    func getMediaURL() -> URL? {
        do {
            guard let downloadFolder = item.downloadFolder else { return nil }
            let contents = try FileManager.default.contentsOfDirectory(atPath: downloadFolder.path)

            guard let mediaFilename = contents.first(where: { $0.starts(with: "Media") }) else { return nil }

            return downloadFolder.appendingPathComponent(mediaFilename)
        } catch {
            return nil
        }
    }

    // MARK: - StoredDownloadItem Creation

    private func createStoredDownloadItem() -> StoredDownloadItem {
        // Build relative paths for stored data
        let relativePath = relativeFolderPath ?? ""

        var mediaRelativePath: String?
        if let mediaURL = getMediaURL() {
            mediaRelativePath = relativePath + "/" + mediaURL.lastPathComponent
        }

        var primaryImageRelativePath: String?
        if let primaryURL = getImageURL(name: "Primary") {
            primaryImageRelativePath = relativePath + "/Images/" + primaryURL.lastPathComponent
        }

        var backdropImageRelativePath: String?
        if let backdropURL = getImageURL(name: "Backdrop") {
            backdropImageRelativePath = relativePath + "/Images/" + backdropURL.lastPathComponent
        }

        var logoImageRelativePath: String?
        if let logoURL = getImageURL(name: "Logo") {
            logoImageRelativePath = relativePath + "/Images/" + logoURL.lastPathComponent
        }

        // Get file size
        var fileSize: Int64?
        if let mediaURL = getMediaURL() {
            let attributes = try? FileManager.default.attributesOfItem(atPath: mediaURL.path)
            fileSize = attributes?[.size] as? Int64
        }

        return StoredDownloadItem(
            item: item,
            downloadedAt: Date(),
            fileSize: fileSize,
            mediaPath: mediaRelativePath,
            primaryImagePath: primaryImageRelativePath,
            backdropImagePath: backdropImageRelativePath,
            logoImagePath: logoImageRelativePath
        )
    }
}

// MARK: - URLSessionDownloadDelegate

extension DownloadTask: URLSessionDownloadDelegate {

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)

        DispatchQueue.main.async {
            self.updateProgress(bytesWritten: totalBytesWritten, totalBytes: totalBytesExpectedToWrite)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        guard let error else { return }

        DispatchQueue.main.async {
            self.state = .error(error.localizedDescription)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }

        DispatchQueue.main.async {
            self.state = .error(error.localizedDescription)
        }
    }
}
