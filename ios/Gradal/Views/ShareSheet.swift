import SwiftUI
import UIKit

/// A file to hand to the system share sheet.
struct SharedFile: Identifiable {
    let url: URL
    var id: String { url.path }
}

/// UIActivityViewController for SwiftUI.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
