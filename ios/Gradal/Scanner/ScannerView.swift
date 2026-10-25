import AVFoundation
import SwiftUI
import UIKit

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer {
        // layerClass guarantees the type.
        layer as! AVCaptureVideoPreviewLayer
    }
}

struct CameraPreview: UIViewRepresentable {
    let model: ScannerModel

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.backgroundColor = .black
        view.previewLayer.session = model.camera.session
        view.previewLayer.videoGravity = .resizeAspectFill
        model.previewLayer = view.previewLayer
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {}
}

struct MarkerOutline: Shape {
    var points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard points.count == 4 else { return path }
        path.move(to: points[0])
        for p in points.dropFirst() { path.addLine(to: p) }
        path.closeSubpath()
        return path
    }
}

/// Scans any Gradal sheet: the quiz comes from the barcode.
struct ScannerView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = ScannerModel()

    var body: some View {
        ZStack {
            // Camera and outline share one coordinate space, never mirrored.
            CameraPreview(model: model)
                .overlay(MarkerOutline(points: model.outline).stroke(Color.green, lineWidth: 4))
                .environment(\.layoutDirection, .leftToRight)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.title2.bold())
                            .padding(12)
                            .background(Color.black.opacity(0.55), in: Circle())
                    }
                    Spacer()
                    Text("الأوراق: \(model.count)")
                        .font(.headline)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.55), in: Capsule())
                    Spacer()
                    Button {
                        model.toggleTorch()
                    } label: {
                        Image(systemName: model.torchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                            .font(.title2.bold())
                            .padding(12)
                            .background(Color.black.opacity(0.55), in: Circle())
                    }
                }
                .foregroundColor(.white)
                .padding(.horizontal)

                Spacer()

                Text(model.status)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.6), in: Capsule())
                    .foregroundColor(.white)

                if let card = model.lastCard {
                    ResultCardView(card: card)
                        .padding(.horizontal)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 24)

            if model.denied {
                VStack(spacing: 12) {
                    Text("لا يمكن استخدام الكاميرا")
                        .font(.title3.bold())
                    Text("اسمح لـ Gradal باستخدام الكاميرا من الإعدادات، ثم ارجع.")
                        .multilineTextAlignment(.center)
                    Button("فتح الإعدادات") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(24)
                .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 16))
                .padding()
            }
        }
        .background(Color.black)
        .onAppear {
            let store = self.store
            model.updateGrids(store.scanGrids)
            model.onAccept = { read, jpeg in
                store.addScan(read: read, jpeg: jpeg)
            }
            model.start()
        }
        .onChange(of: store.db.quizzes) { _, _ in
            model.updateGrids(store.scanGrids)
        }
        .onDisappear {
            model.stop()
        }
    }
}

struct ResultCardView: View {
    let card: ResultCard

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: card.known ? "checkmark.circle.fill" : "questionmark.circle.fill")
                .font(.system(size: 34))
                .foregroundColor(card.known ? .green : .orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(card.name).font(.headline)
                Text(card.quizName)
                    .font(.subheadline)
                    .foregroundColor(card.percent == nil ? .orange : .secondary)
                Text(card.score).font(.subheadline).foregroundColor(.secondary)
            }
            Spacer()
            if let percent = card.percent {
                Text("\(percent)٪")
                    .font(.title.bold())
                    .monospacedDigit()
            }
        }
        .padding(16)
        .background(Color(.systemBackground).opacity(0.95), in: RoundedRectangle(cornerRadius: 16))
    }
}
