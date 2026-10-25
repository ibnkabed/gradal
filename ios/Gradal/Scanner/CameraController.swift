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
    static func encode(_ image: GrayImage, quality: CGFloat = 0.6) -> Data? {
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
final class CameraController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
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
            if camera.isFocusModeSupported(.continuousAutoFocus) { camera.focusMode = .continuousAutoFocus }
            if camera.isAutoFocusRangeRestrictionSupported { camera.autoFocusRangeRestriction = .near }
            camera.unlockForConfiguration()
        } catch {}
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(output) { session.addOutput(output) }
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
            let page = SheetReader.warpPage(gray, read.homography, layouts)
            let jpeg = GrayJPEG.encode(page)
            onEvent?(.accepted(read: read, jpeg: jpeg, corners: corners, size: size))
        } else {
            previousKey = key
            onEvent?(.seen(corners: corners, size: size, holding: false))
        }
    }
}
