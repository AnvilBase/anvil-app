import SwiftUI

/// A photo shown full screen when you tap it in the chat.
///
/// Pinch or double-tap to zoom, drag to move around while zoomed, and swipe down or tap Close to
/// dismiss. Photos are stored at the size the model was given, so this shows that version.
struct PhotoViewer: View {
  let image: CGImage

  @Environment(\.dismiss) private var dismiss
  @State private var scale: CGFloat = 1
  @State private var steadyScale: CGFloat = 1
  @State private var offset: CGSize = .zero
  @State private var steadyOffset: CGSize = .zero
  /// How far the photo has been dragged down to dismiss it.
  @State private var dismissDrag: CGFloat = 0

  private static let maxScale: CGFloat = 5
  private static let doubleTapScale: CGFloat = 2.5

  var body: some View {
    ZStack {
      Color.black
        .opacity(backgroundOpacity)
        .ignoresSafeArea()

      Image(image, scale: 1, label: Text("Photo"))
        .resizable()
        .scaledToFit()
        .scaleEffect(scale)
        .offset(x: offset.width, y: offset.height + dismissDrag)
        .gesture(magnify.simultaneously(with: drag))
        .onTapGesture(count: 2) {
          withAnimation(.spring) { toggleZoom() }
        }
        .accessibilityAddTraits(.isImage)
        .accessibilityHint("Double-tap to zoom")
    }
    .overlay(alignment: .top) {
      HStack {
        ShareLink(
          item: Image(image, scale: 1, label: Text("Photo")),
          preview: SharePreview("Photo", image: Image(image, scale: 1, label: Text("Photo")))
        ) {
          Image(systemName: "square.and.arrow.up")
            .font(.body.weight(.semibold))
            .frame(width: ChatStyle.control, height: ChatStyle.control)
            .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityLabel("Share photo")

        Spacer()

        Button {
          dismiss()
        } label: {
          Image(systemName: "xmark")
            .font(.body.weight(.semibold))
            .frame(width: ChatStyle.control, height: ChatStyle.control)
            .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityLabel("Close")
      }
      .foregroundStyle(.white)
      .padding(.horizontal)
      .opacity(dismissDrag > 0 ? 0 : 1)
    }
    .presentationBackground(.clear)
    .statusBarHidden()
  }

  private var backgroundOpacity: Double {
    1 - min(Double(dismissDrag) / 400, 0.7)
  }

  private var magnify: some Gesture {
    MagnifyGesture()
      .onChanged { value in
        scale = min(max(steadyScale * value.magnification, 1), Self.maxScale)
      }
      .onEnded { _ in
        steadyScale = scale
        if scale <= 1 {
          withAnimation(.spring) { resetZoom() }
        }
      }
  }

  private var drag: some Gesture {
    DragGesture()
      .onChanged { value in
        if scale > 1 {
          offset = CGSize(
            width: steadyOffset.width + value.translation.width,
            height: steadyOffset.height + value.translation.height)
        } else {
          dismissDrag = max(0, value.translation.height)
        }
      }
      .onEnded { value in
        if scale > 1 {
          steadyOffset = offset
        } else if value.translation.height > 120 || value.predictedEndTranslation.height > 300 {
          dismiss()
        } else {
          withAnimation(.spring) { dismissDrag = 0 }
        }
      }
  }

  private func toggleZoom() {
    if scale > 1 {
      resetZoom()
    } else {
      scale = Self.doubleTapScale
      steadyScale = Self.doubleTapScale
    }
  }

  private func resetZoom() {
    scale = 1
    steadyScale = 1
    offset = .zero
    steadyOffset = .zero
  }
}
