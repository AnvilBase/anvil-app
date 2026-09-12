#if canImport(UIKit)
  import SwiftUI
  import UIKit

  /// The system camera. The photo is handed to the chat as JPEG data and isn't saved to the photo
  /// library.
  struct CameraPicker: UIViewControllerRepresentable {
    static var isAvailable: Bool {
      UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    /// Called with the photo, or nil if the user cancels.
    let onFinish: (Data?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
      let picker = UIImagePickerController()
      picker.sourceType = .camera
      picker.delegate = context.coordinator
      return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
      Coordinator(onFinish: onFinish)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
      private let onFinish: (Data?) -> Void

      init(onFinish: @escaping (Data?) -> Void) {
        self.onFinish = onFinish
      }

      func imagePickerController(
        _ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
      ) {
        let image = info[.originalImage] as? UIImage
        onFinish(image?.jpegData(compressionQuality: 0.9))
      }

      func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        onFinish(nil)
      }
    }
  }
#endif
