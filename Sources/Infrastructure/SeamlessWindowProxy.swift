import AppKit
import AVFoundation
import CoreMedia
import UniSpaceDomain

@MainActor
public final class SeamlessWindowProxy: NSObject, NSWindowDelegate {
    public var onInput: ((SeamlessInput) -> Void)?
    public var onClose: (() -> Void)?
    public var onVisibility: ((Bool) -> Void)?
    public var onKeyframeNeeded: (() -> Void)?
    private let window: NSWindow
    private let surface = WindowVideoSurface(frame: .zero)
    private var closing = false
    private var format: CMVideoFormatDescription?
    private var parameters: [Data] = []
    private var needsKeyframe = true
    var nativeWindow: NSWindow { window }

    public init(descriptor: SeamlessWindowDescriptor, sourceName: String) {
        let scale = min(1, 1_000 / Double(descriptor.width), 700 / Double(descriptor.height))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Double(descriptor.width) * scale,
            height: Double(descriptor.height) * scale), styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        super.init()
        window.title = "\(descriptor.title) — \(sourceName)"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 160, height: 100)
        window.contentView = surface
        window.delegate = self
        window.acceptsMouseMovedEvents = true
        surface.input = { [weak self] in self?.onInput?($0) }
        surface.emergencyStop = { [weak self] in self?.onClose?() }
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(surface)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// AVSampleBufferDisplayLayer owns hardware decoding. No unbounded array of
    /// frames is retained: after a decoder stall, wait for an IDR to recover.
    @discardableResult public func display(_ frame: SeamlessVideoFrame) throws -> Bool {
        try frame.validate()
        guard !window.isMiniaturized else { return false }
        if surface.video.status == .failed || !surface.video.isReadyForMoreMediaData {
            surface.video.flushAndRemoveImage(); needsKeyframe = true
            surface.inputEnabled = false; onInput?(SeamlessInput(kind: .releaseAll))
            onKeyframeNeeded?()
        }
        let changed = parameters != [frame.sps, frame.pps]
        guard (!needsKeyframe && !changed) || frame.keyframe else { return false }
        if changed {
            var next: CMFormatDescription?
            let status = frame.sps.withUnsafeBytes { sps in
                frame.pps.withUnsafeBytes { pps in
                    let pointers = [sps.bindMemory(to: UInt8.self).baseAddress!, pps.bindMemory(to: UInt8.self).baseAddress!]
                    let sizes = [sps.count, pps.count]
                    return pointers.withUnsafeBufferPointer { pointers in
                        sizes.withUnsafeBufferPointer { sizes in
                            CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault,
                                parameterSetCount: 2, parameterSetPointers: pointers.baseAddress!,
                                parameterSetSizes: sizes.baseAddress!, nalUnitHeaderLength: 4, formatDescriptionOut: &next)
                        }
                    }
                }
            }
            guard status == noErr, let next else { throw SeamlessWindowError.invalidMessage }
            let size = CMVideoFormatDescriptionGetDimensions(next)
            guard size.width == frame.width, size.height == frame.height else { throw SeamlessWindowError.invalidMessage }
            format = next; parameters = [frame.sps, frame.pps]
            surface.video.flushAndRemoveImage()
        }
        guard let format else { throw SeamlessWindowError.invalidMessage }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        guard dimensions.width == frame.width, dimensions.height == frame.height else { throw SeamlessWindowError.invalidMessage }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: frame.bytes.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: frame.bytes.count, flags: 0, blockBufferOut: &block) == noErr,
              let block else { throw SeamlessWindowError.unavailable }
        let copied = frame.bytes.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: $0.count)
        }
        guard copied == noErr else { throw SeamlessWindowError.unavailable }
        var sample: CMSampleBuffer?
        var size = frame.bytes.count
        var timing = CMSampleTimingInfo(duration: .invalid,
            presentationTimeStamp: CMTime(seconds: ProcessInfo.processInfo.systemUptime, preferredTimescale: 1_000_000),
            decodeTimeStamp: .invalid)
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
              let sample else { throw SeamlessWindowError.unavailable }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        surface.sourceSize = CGSize(width: frame.width, height: frame.height)
        surface.video.enqueue(sample)
        surface.inputEnabled = true
        needsKeyframe = false
        return true
    }

    public func close() {
        closing = true
        surface.video.flushAndRemoveImage()
        surface.input = nil; surface.emergencyStop = nil
        window.close()
    }

    public func windowWillClose(_ notification: Notification) { if !closing { onClose?() } }
    public func windowDidResignKey(_ notification: Notification) { onInput?(SeamlessInput(kind: .releaseAll)) }
    public func windowDidMiniaturize(_ notification: Notification) { onInput?(SeamlessInput(kind: .releaseAll)); onVisibility?(false) }
    public func windowDidDeminiaturize(_ notification: Notification) { needsKeyframe = true; onVisibility?(true); onKeyframeNeeded?() }
}

@MainActor
private final class WindowVideoSurface: NSView {
    let video = AVSampleBufferDisplayLayer()
    var sourceSize = CGSize(width: 16, height: 16)
    var inputEnabled = false
    var input: ((SeamlessInput) -> Void)?
    var emergencyStop: (() -> Void)?
    private var tracking: NSTrackingArea?
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        video.videoGravity = .resizeAspect
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(video)
        setAccessibilityLabel("Remote application window")
        setAccessibilityHelp("Control Option Command Escape returns the window to its source Mac.")
    }
    required init?(coder: NSCoder) { nil }
    override func layout() { super.layout(); video.frame = bounds }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let next = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(next); tracking = next
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseMoved(with event: NSEvent) { pointer(event, .move) }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); pointer(event, .leftDown) }
    override func mouseUp(with event: NSEvent) { pointer(event, .leftUp) }
    override func rightMouseDown(with event: NSEvent) { pointer(event, .rightDown) }
    override func rightMouseUp(with event: NSEvent) { pointer(event, .rightUp) }
    override func mouseDragged(with event: NSEvent) { pointer(event, .leftDrag) }
    override func rightMouseDragged(with event: NSEvent) { pointer(event, .rightDrag) }
    override func scrollWheel(with event: NSEvent) { pointer(event, .scroll) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 && event.modifierFlags.intersection([.command, .control, .option]) == [.command, .control, .option] {
            emergencyStop?(); return
        }
        keyboard(event, .keyDown)
    }
    override func keyUp(with event: NSEvent) { keyboard(event, .keyUp) }
    override func flagsChanged(with event: NSEvent) { keyboard(event, .flagsChanged) }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.isKeyWindow == true else { return false }
        keyDown(with: event); return true
    }
    private func keyboard(_ event: NSEvent, _ kind: SeamlessInput.Kind) {
        guard inputEnabled else { return }
        input?(SeamlessInput(kind: kind, keyCode: event.keyCode, modifiers: UInt64(event.modifierFlags.rawValue) & 0x00ff0000))
    }
    private func pointer(_ event: NSEvent, _ kind: SeamlessInput.Kind) {
        guard inputEnabled else { return }
        let scale = min(bounds.width / sourceSize.width, bounds.height / sourceSize.height)
        guard scale.isFinite, scale > 0 else { return }
        let rect = CGRect(x: (bounds.width - sourceSize.width * scale) / 2,
                          y: (bounds.height - sourceSize.height * scale) / 2,
                          width: sourceSize.width * scale, height: sourceSize.height * scale)
        let point = convert(event.locationInWindow, from: nil)
        // Button-up outside the letterbox still releases the held button.
        guard rect.contains(point) || [.leftUp, .rightUp, .leftDrag, .rightDrag].contains(kind) else { return }
        input?(SeamlessInput(kind: kind, x: min(1, max(0, (point.x - rect.minX) / rect.width)),
            y: min(1, max(0, (point.y - rect.minY) / rect.height)),
            modifiers: UInt64(event.modifierFlags.rawValue) & 0x00ff0000,
            deltaX: kind == .scroll ? max(-4_096, min(4_096, Double(event.scrollingDeltaX))) : 0,
            deltaY: kind == .scroll ? max(-4_096, min(4_096, Double(event.scrollingDeltaY))) : 0))
    }
}
