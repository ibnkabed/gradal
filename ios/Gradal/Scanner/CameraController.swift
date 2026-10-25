import AVFoundation
import CoreVideo
import UIKit

enum ScanEvent {
    case nothing
    case seen(corners: [CGPoint], size: CGSize, holding: Bool)
    /// A Gradal sheet whose answers cannot be read here: unknown code, or no sheet from the PC yet.
    case blocked(code: Int, known: Bool, corners: [CGPoint], size: CGSize)
    case accepted(read: SheetRead, jpeg: Data?, corners: [CGPoint], size: CGSize)
}

/// Encodes a grayscale image as JPEG (the straightened review sheet).
enum GrayJPEG {
    static func encode(_ image: GrayImage, quality: CGFloat = 0.85) -> Data? {
        let data = Data(image.pixels) as CFData
        guard let provider = CGDataProvider(data: data),
              let cg = CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 8,
                               bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false,
                               intent: .defaultIntent)
        else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: quality)
    }
}

/// Quiz code -> question positions, shared between the main thread and the video queue.
final class ScanGrids: @unchecked Sendable {
    private let lock = NSLock()
    private var table: [Int: ScanGrid] = [:]

    func set(_ value: [Int: ScanGrid]) {
        lock.lock()
        table = value
        lock.unlock()
    }

    func grid(for code: Int) -> ScanGrid? {
        lock.lock()
        defer { lock.unlock() }
        return table[code]
    }
}

/// Back camera → Y plane → SheetReader, on a serial queue that drops frames while busy.
/// A paper is accepted when two consecutive reads agree; then nothing more is accepted until the
/// markers have been gone for 0.7 s or a different paper (quiz code or student ID) shows up.
/// The answers come from the video frame; the review copy from a full-resolution still taken right then
/// (owner, 2026-10-25: the 1080p frame was too blurred to check a paper by), or from the frame if the still
/// does not show the same paper.
final class CameraController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()
    var onEvent: (@Sendable (ScanEvent) -> Void)?

    private let sessionQueue = DispatchQueue(label: "gradal.camera.session")
    private let videoQueue = DispatchQueue(label: "gradal.camera.video")
    private var device: AVCaptureDevice?
    private var configured = false

    private let layouts: SheetLayouts?
    let grids = ScanGrids()

    // Video-queue state.
    private var previousKey: String?
    private var locked = false
    private var lockedId = ""
    private var lastSeen: TimeInterval = 0
    private let photoOutput = AVCapturePhotoOutput()
    private var photoReady = false
    private struct Pending {
        let read: SheetRead
        let frame: GrayImage
        let corners: [CGPoint]
        let size: CGSize
    }
    private var pending: Pending?

    init(layouts: SheetLayouts?) {
        self.layouts = layouts
        super.init()
    }

    func start() {
        sessionQueue.async { [self] in
            if !configured {
                configure()
                configured = true
            }
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        sessionQueue.async { [self] in
            if let device, device.hasTorch {
                do {
                    try device.lockForConfiguration()
                    device.torchMode = .off
                    device.unlockForConfiguration()
                } catch {}
            }
            if session.isRunning { session.stopRunning() }
        }
    }

    func setTorch(_ on: Bool) {
        sessionQueue.async { [self] in
            guard let device, device.hasTorch else { return }
            do {
                try device.lockForConfiguration()
                device.torchMode = on ? .on : .off
                device.unlockForConfiguration()
            } catch {}
        }
    }

    private func configure() {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if session.canSetSessionPreset(.hd1920x1080) { session.sessionPreset = .hd1920x1080 }
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(input) else { return }
        session.addInput(input)
        device = camera
        do {
            try camera.lockForConfiguration()
            // a 1080p format whose stills are as large as the camera allows (the review copy)
            let wide = camera.formats.filter {
                let d = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                return d.width == 1920 && d.height == 1080
            }
            func stillArea(_ f: AVCaptureDevice.Format) -> Int32 {
                f.supportedMaxPhotoDimensions.map { $0.width * $0.height }.max() ?? 0
            }
            if let best = wide.max(by: { stillArea($0) < stillArea($1) }), stillArea(best) > stillArea(camera.activeFormat) {
                camera.activeFormat = best
            }
            if camera.isFocusModeSupported(.continuousAutoFocus) { camera.focusMode = .continuousAutoFocus }
            if camera.isAutoFocusRangeRestrictionSupported { camera.autoFocusRangeRestriction = .near }
            camera.unlockForConfiguration()
        } catch {}
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(output) { session.addOutput(output) }
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            if let largest = camera.activeFormat.supportedMaxPhotoDimensions.max(by: { $0.width * $0.height < $1.width * $1.height }) {
                photoOutput.maxPhotoDimensions = largest
            }
            photoOutput.maxPhotoQualityPrioritization = .balanced
            photoReady = photoOutput.availablePhotoPixelFormatTypes.contains(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        }
    }

    private func takeStill() {
        let settings = AVCapturePhotoSettings(format: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ])
        settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
        settings.photoQualityPrioritization = .balanced
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let still = error == nil ? photo.pixelBuffer.flatMap { Self.luma($0) } : nil
        videoQueue.async { [self] in finish(still) }
    }

    /// The accepted paper's review copy: from the still when it shows the same paper, else from the frame.
    private func finish(_ still: GrayImage?) {
        guard let p = pending, let layouts else { return }
        pending = nil
        var page: GrayImage?
        if let still, let found = SheetReader.locate(still, layouts),
           found.code == p.read.quizCode, found.version == p.read.version {
            page = ReviewImage.warp(still, found.h, widthMm: layouts.page.widthMm, heightMm: layouts.page.heightMm)
        }
        let review = page ?? ReviewImage.warp(p.frame, p.read.homography, widthMm: layouts.page.widthMm,
                                             heightMm: layouts.page.heightMm)
        onEvent?(.accepted(read: p.read, jpeg: GrayJPEG.encode(review), corners: p.corners, size: p.size))
    }

    /// The luma plane as a tight grayscale image (bytesPerRow respected).
    static func luma(_ buffer: CVPixelBuffer) -> GrayImage? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let h = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        guard w > 0, h > 0, let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let src = base.assumingMemoryBound(to: UInt8.self)
        var pixels = [UInt8](repeating: 0, count: w * h)
        pixels.withUnsafeMutableBufferPointer { dst in
            guard let out = dst.baseAddress else { return }
            for y in 0..<h {
                memcpy(out + y * w, src + y * rowBytes, w)
            }
        }
        return GrayImage(width: w, height: h, pixels: pixels)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let layouts, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let gray = Self.luma(buffer) else { return }
        let size = CGSize(width: gray.width, height: gray.height)
        let now = ProcessInfo.processInfo.systemUptime
        guard let located = SheetReader.locate(gray, layouts) else {
            previousKey = nil
            if locked && now - lastSeen > 0.7 { locked = false }
            onEvent?(.nothing)
            return
        }
        lastSeen = now
        if pending != nil { return }          // the still of the accepted paper is on its way
        let corners = located.corners.map { CGPoint(x: $0.x, y: $0.y) }
        // Answers are read only at the quiz's own positions (quiz.sheet from the PC).
        guard let grid = grids.grid(for: located.code),
              let bubbles = grid.bubbles, bubbles.count >= grid.questionCount else {
            previousKey = nil
            let known = grids.grid(for: located.code) != nil
            onEvent?(.blocked(code: located.code, known: known, corners: corners, size: size))
            return
        }
        let read = SheetReader.readBubbles(gray, layouts, located, questionCount: grid.questionCount,
                                           questionBubbles: bubbles)
        let paperId = "\(read.quizCode)/\(read.studentId)"
        if locked {
            if paperId == lockedId {
                onEvent?(.seen(corners: corners, size: size, holding: true))
                return
            }
            locked = false
        }
        let key = paperId + "|" + String(read.version) + "|" + read.answers.joined(separator: ",")
        if key == previousKey {
            previousKey = nil
            locked = true
            lockedId = paperId
            pending = Pending(read: read, frame: gray, corners: corners, size: size)
            if photoReady {
                takeStill()
            } else {
                finish(nil)
            }
        } else {
            previousKey = key
            onEvent?(.seen(corners: corners, size: size, holding: false))
        }
    }
}
