import Foundation
import UniSpaceDomain

public enum FileTransferTransportEvent: Sendable, Equatable {
    case connected(DeviceID)
    case disconnected(DeviceID)
    case message(DeviceID, FileTransferEnvelope)
    case failure(DeviceID?, FileTransferFailureCode)
}

public protocol FileTransferTransport: Sendable {
    func start(localDevice: DeviceDescriptor, workspace: WorkspaceSnapshot, key: Data) async throws
    func stop() async
    func events() -> AsyncStream<FileTransferTransportEvent>
    func send(_ envelope: FileTransferEnvelope, to deviceID: DeviceID) async throws
}

public struct PreparedOutgoingTransfer: Sendable, Equatable {
    public let manifest: TransferManifest

    public init(manifest: TransferManifest) {
        self.manifest = manifest
    }
}

public protocol FileSourceProvider: Sendable {
    func prepare(
        urls: [URL],
        transferID: TransferID,
        workspaceID: WorkspaceID,
        sourceDeviceID: DeviceID,
        destinationDeviceID: DeviceID,
        limits: FileTransferLimits
    ) async throws -> PreparedOutgoingTransfer

    func readChunk(
        transferID: TransferID,
        entryID: TransferEntryID,
        offset: UInt64,
        maximumLength: Int
    ) async throws -> Data

    func recoverOutgoingTransfers(limits: FileTransferLimits) async throws -> [PreparedOutgoingTransfer]
    func removeOutgoingTransfer(_ transferID: TransferID) async
}

public protocol TransferStore: Sendable {
    func prepareIncoming(manifest: TransferManifest, limits: FileTransferLimits) async throws
    func write(_ chunk: TransferChunk, limits: FileTransferLimits) async throws -> UInt64
    func verifiedOffsets(for transferID: TransferID) async throws -> [TransferEntryOffset]
    func finalizeEntry(transferID: TransferID, entryID: TransferEntryID) async throws -> URL
    func finalizeTransfer(_ transferID: TransferID) async throws -> [URL]
    func completedURLs(for transferID: TransferID) async throws -> [URL]
    func recoverIncomingTransfers(limits: FileTransferLimits) async throws -> [RecoveredIncomingTransfer]
    func cancel(_ transferID: TransferID) async
    func remove(_ transferID: TransferID) async
    func removeExpired(now: Date, limits: FileTransferLimits) async
}

public struct RecoveredIncomingTransfer: Sendable, Equatable {
    public let manifest: TransferManifest
    public let offsets: [TransferEntryOffset]
    public let completedURLs: [URL]

    public init(
        manifest: TransferManifest,
        offsets: [TransferEntryOffset],
        completedURLs: [URL] = []
    ) {
        self.manifest = manifest
        self.offsets = offsets
        self.completedURLs = completedURLs
    }

    public var isCompleted: Bool { !completedURLs.isEmpty }
}

public struct PasteboardFileSelection: Sendable, Equatable {
    public let changeCount: Int
    public let urls: [URL]

    public init(changeCount: Int, urls: [URL]) {
        self.changeCount = changeCount
        self.urls = urls
    }
}

@MainActor
public protocol FilePasteboard: AnyObject, Sendable {
    func events() -> AsyncStream<PasteboardFileSelection>
    func publishFiles(_ urls: [URL], transferID: TransferID)
}

public struct FileTransferSnapshot: Identifiable, Sendable, Equatable {
    public let id: TransferID
    public let direction: FileTransferDirection
    public let peerDeviceID: DeviceID
    public let displayName: String
    public let fileCount: Int
    public let totalByteCount: UInt64
    public let transferredByteCount: UInt64
    public let state: FileTransferState
    public let failureCode: FileTransferFailureCode?
    public let createdAt: Date
    public let completedAt: Date?
    public let stagedURLs: [URL]

    public init(
        id: TransferID,
        direction: FileTransferDirection,
        peerDeviceID: DeviceID,
        displayName: String,
        fileCount: Int,
        totalByteCount: UInt64,
        transferredByteCount: UInt64,
        state: FileTransferState,
        failureCode: FileTransferFailureCode? = nil,
        createdAt: Date,
        completedAt: Date? = nil,
        stagedURLs: [URL] = []
    ) {
        self.id = id
        self.direction = direction
        self.peerDeviceID = peerDeviceID
        self.displayName = displayName
        self.fileCount = fileCount
        self.totalByteCount = totalByteCount
        self.transferredByteCount = min(transferredByteCount, totalByteCount)
        self.state = state
        self.failureCode = failureCode
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.stagedURLs = stagedURLs
    }

    public var progress: Double {
        guard totalByteCount > 0 else { return state == .completed ? 1 : 0 }
        return min(Double(transferredByteCount) / Double(totalByteCount), 1)
    }

    public var isActive: Bool { !state.isTerminal }
}

public enum FileTransferCoordinatorEvent: Sendable, Equatable {
    case snapshot(FileTransferSnapshot)
    case removed(TransferID)
}

public enum FileTransferCoordinatorError: Error, LocalizedError, Equatable, Sendable {
    case noDestination
    case peerUnavailable(DeviceID)
    case peerBusy(DeviceID)
    case transferNotFound(TransferID)
    case invalidState(FileTransferState)
    case sourceChanged
    case transferRejected

    public var errorDescription: String? {
        switch self {
        case .noDestination:
            "Choose an online Mac before sending files."
        case .peerUnavailable:
            "The destination Mac is not available for file transfer."
        case .peerBusy:
            "Another file transfer is already active for that Mac."
        case .transferNotFound:
            "The transfer no longer exists."
        case .invalidState:
            "The transfer cannot perform that action in its current state."
        case .sourceChanged:
            "A source file changed while it was being transferred."
        case .transferRejected:
            "The destination Mac rejected the transfer."
        }
    }
}
