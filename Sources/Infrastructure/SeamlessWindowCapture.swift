import AppKit
import CoreMedia
import ScreenCaptureKit
import VideoToolbox
import UniSpaceDomain

@MainActor
public final class SeamlessWindowCapture {
    public private(set) var windows: [RemoteWindowID: SCWindow] = [:]
    private var stream: SCStream?
    private var output: WindowH264Output?

    public init() {}

    public func catalog() async throws -> [SeamlessWindowDescriptor] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        var next: [RemoteWindowID: SCWindow] = [:]
        var descriptors: [SeamlessWindowDescriptor] = []
        for window in content.windows where window.windowLayer == 0 &&
            window.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier {
            guard let app = window.owningApplication, window.frame.width >= 16, window.frame.height >= 16 else { continue }
            let id = windows.first(where: { $0.value.windowID == window.windowID &&
                $0.value.owningApplication?.processID == app.processID })?.key ?? RemoteWindowID()
            let descriptor = SeamlessWindowDescriptor(id: id,
                title: String((window.title ?? app.applicationName).prefix(256)),
                application: String(app.applicationName.prefix(64)),
                width: Int(window.frame.width), height: Int(window.frame.height))
            guard (try? descriptor.validate()) != nil else { continue }
            next[id] = window; descriptors.append(descriptor)
        }
        windows = next
        return descriptors.sorted { $0.application.localizedStandardCompare($1.application) == .orderedAscending }
    }

    public func start(id: RemoteWindowID, epoch: UUID,
                      onFrame: @escaping @MainActor @Sendable (SeamlessVideoFrame) -> Bool,
                      onFailure: @escaping @MainActor @Sendable () -> Void) async throws {
        await stop()
        guard let window = windows[id] else { throw SeamlessWindowError.unavailable }
        let ratio = min(1, min(1_920 / window.frame.width, 1_080 / window.frame.height))
        let width = max(16, Int(window.frame.width * ratio) / 2 * 2)
        let height = max(16, Int(window.frame.height * ratio) / 2 * 2)
        let output = try WindowH264Output(epoch: epoch, width: width, height: height,
                                        onFrame: onFrame, onFailure: onFailure)
        let configuration = SCStreamConfiguration()
        configuration.width = width; configuration.height = height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 3
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.scalesToFit = true
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window),
                              configuration: configuration, delegate: output)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
        self.stream = stream; self.output = output
        do { try await stream.startCapture() }
        catch { await stop(); throw error }
    }

    public func requestKeyframe() { output?.requestKeyframe() }

    public func stop() async {
        let old = stream
        let oldOutput = output
        stream = nil; output = nil
        try? await old?.stopCapture()
        oldOutput?.stop()
    }
}

/// Capture and encoder state are serialized by queue; gate bounds the number of
/// outstanding encode/presentation callbacks to one (including the main actor).
private final class WindowH264Output: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.layatai.unispace.window.encode", qos: .userInitiated)
    private let gate = DispatchSemaphore(value: 1)
    private let lock = NSLock()
    private var forceKey = true
    private var stopped = false
    private var session: VTCompressionSession?
    private var sequence: UInt64 = 0
    private let epoch: UUID
    private let width: Int
    private let height: Int
    private let onFrame: @MainActor @Sendable (SeamlessVideoFrame) -> Bool
    private let onFailure: @MainActor @Sendable () -> Void

    init(epoch: UUID, width: Int, height: Int,
         onFrame: @escaping @MainActor @Sendable (SeamlessVideoFrame) -> Bool,
         onFailure: @escaping @MainActor @Sendable () -> Void) throws {
        self.epoch = epoch; self.width = width; self.height = height
        self.onFrame = onFrame; self.onFailure = onFailure
        super.init()
        let status = VTCompressionSessionCreate(allocator: kCFAllocatorDefault,
            width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true] as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: { ref, _, status, _, sample in
                guard let ref else { return }
                let owner = Unmanaged<WindowH264Output>.fromOpaque(ref).takeUnretainedValue()
                owner.encoded(status: status, sample: sample)
            }, refcon: Unmanaged.passUnretained(self).toOpaque(), compressionSessionOut: &session)
        guard status == noErr, let session else { throw SeamlessWindowError.unavailable }
        for (key, value) in [
            (kVTCompressionPropertyKey_RealTime, kCFBooleanTrue as CFTypeRef),
            (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse as CFTypeRef),
            (kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: 8_000_000)),
            (kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: 60)),
            (kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: 30))
        ] {
            guard VTSessionSetProperty(session, key: key, value: value) == noErr else {
                VTCompressionSessionInvalidate(session)
                self.session = nil
                throw SeamlessWindowError.unavailable
            }
        }
        guard VTCompressionSessionPrepareToEncodeFrames(session) == noErr else {
            VTCompressionSessionInvalidate(session); self.session = nil
            throw SeamlessWindowError.unavailable
        }
    }

    func requestKeyframe() { lock.lock(); forceKey = true; lock.unlock() }

    func stop() {
        lock.lock(); stopped = true; lock.unlock()
        queue.sync {
            if let session {
                VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
                VTCompressionSessionInvalidate(session)
            }
            session = nil
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Task { @MainActor [onFailure] in onFailure() }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer),
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int,
              status == SCFrameStatus.complete.rawValue,
              let image = CMSampleBufferGetImageBuffer(sampleBuffer), let session,
              gate.wait(timeout: .now()) == .success else { return }
        lock.lock()
        let stop = stopped; let keyframe = forceKey; forceKey = false
        lock.unlock()
        guard !stop else { gate.signal(); return }
        let properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: keyframe] as CFDictionary
        let result = VTCompressionSessionEncodeFrame(session, imageBuffer: image,
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer), duration: .invalid,
            frameProperties: properties, sourceFrameRefcon: nil, infoFlagsOut: nil)
        if result != noErr { requestKeyframe(); gate.signal() }
    }

    private func encoded(status: OSStatus, sample: CMSampleBuffer?) {
        guard status == noErr, let sample, let format = CMSampleBufferGetFormatDescription(sample),
              let block = CMSampleBufferGetDataBuffer(sample) else { gate.signal(); requestKeyframe(); return }
        func parameter(_ index: Int) -> Data? {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
                parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
                  let pointer, size > 0, size <= 4_096 else { return nil }
            return Data(bytes: pointer, count: size)
        }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0, length <= SeamlessWindowLimits.maximumFrameBytes,
              let sps = parameter(0), let pps = parameter(1) else { gate.signal(); requestKeyframe(); return }
        var bytes = Data(count: length)
        let copied = bytes.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
        }
        guard copied == noErr else { gate.signal(); requestKeyframe(); return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let keyframe = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true
        lock.lock()
        let frameSequence = sequence; sequence &+= 1
        let stop = stopped
        lock.unlock()
        guard !stop else { gate.signal(); return }
        let frame = SeamlessVideoFrame(epoch: epoch, sequence: frameSequence, width: width, height: height,
                                      keyframe: keyframe, sps: sps, pps: pps, bytes: bytes)
        Task { @MainActor [self] in
            if !onFrame(frame) { requestKeyframe() }
            gate.signal()
        }
    }
}
