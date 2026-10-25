import AudioToolbox
import AVFoundation
import SwiftUI
import UIKit

@MainActor
final class ScannerModel: ObservableObject {
    @Published var outline: [CGPoint] = []
    @Published var status = "وجّه الكاميرا إلى الورقة كاملة بزواياها الأربع"
    @Published var torchOn = false
    @Published var lastCard: ResultCard?
    @Published var count = 0
    @Published var denied = false

    let camera: CameraController
    weak var previewLayer: AVCaptureVideoPreviewLayer?
    /// Saves the accepted paper and returns the card to show.
    var onAccept: (@MainActor (SheetRead, Data?) -> ResultCard?)?

    init() {
        camera = CameraController(layouts: LayoutStore.shared)
        camera.onEvent = { @Sendable [weak self] event in
            guard let model = self else { return }
            Task { @MainActor in
                model.handle(event)
            }
        }
        if LayoutStore.shared == nil {
            status = "ملف تخطيط الأوراق مفقود من التطبيق."
        }
    }

    /// Quiz code -> question positions (quiz.sheet), so each paper is read at its own layout.
    func updateGrids(_ grids: [Int: ScanGrid]) {
        camera.grids.set(grids)
    }

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            camera.start()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in
                    if granted { self.camera.start() } else { self.denied = true }
                }
            }
        default:
            denied = true
        }
    }

    func stop() {
        camera.stop()
        torchOn = false
    }

    func toggleTorch() {
        torchOn.toggle()
        camera.setTorch(torchOn)
    }

    private func convert(_ corners: [CGPoint], _ size: CGSize) -> [CGPoint] {
        guard let layer = previewLayer, size.width > 0, size.height > 0 else { return [] }
        return corners.map {
            layer.layerPointConverted(fromCaptureDevicePoint: CGPoint(x: $0.x / size.width, y: $0.y / size.height))
        }
    }

    private func handle(_ event: ScanEvent) {
        switch event {
        case .nothing:
            outline = []
            status = lastCard == nil
                ? "وجّه الكاميرا إلى الورقة كاملة بزواياها الأربع"
                : "ضع الورقة التالية"
        case let .blocked(code, known, corners, size):
            outline = convert(corners, size)
            status = known
                ? "افتح الاختبار واحفظه من جديد لتجهيز ورقته"
                : "ورقة اختبار غير موجود في هذا الجوال (\(String(code)))"
        case let .seen(corners, size, holding):
            outline = convert(corners, size)
            status = holding ? "تم حفظ هذه الورقة. ضع الورقة التالية" : "ثبّت الجوال…"
        case let .accepted(read, jpeg, corners, size):
            outline = convert(corners, size)
            if let card = onAccept?(read, jpeg) {
                lastCard = card
                count += 1
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                AudioServicesPlaySystemSound(1057)
                status = "تم حفظ الورقة"
            } else {
                status = "اختبار غير معروف (\(String(read.quizCode))) — زامن أولًا"
            }
        }
    }
}
