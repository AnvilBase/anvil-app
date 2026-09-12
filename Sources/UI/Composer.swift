import PhotosUI
import SwiftUI

#if canImport(UIKit)
  import UIKit
#endif

/// The bar under the chat: the editing banner, the photo waiting to be sent, the web search and
/// camera buttons, the message field, Send / Stop / microphone, and the status line.
struct Composer: View {
  @Bindable var chat: ChatModel
  @FocusState.Binding var isInputFocused: Bool
  let onShowPhoto: (CGImage) -> Void
  let onOpenSettings: () -> Void

  @State private var photoSelection: PhotosPickerItem?
  @State private var showingCamera = false
  @State private var showingPhotoLibrary = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if chat.editingMessageID != nil {
        HStack {
          Label(
            "Editing message: sending replaces it and the replies after it",
            systemImage: "pencil"
          )
          .font(.footnote)
          .foregroundStyle(.secondary)
          Spacer()
          Button("Cancel") { chat.cancelEditing() }
            .font(.footnote)
        }
      }

      pendingPhoto
      controls
      statusLine
    }
    .padding()
    .photosPicker(isPresented: $showingPhotoLibrary, selection: $photoSelection, matching: .images)
    #if canImport(UIKit)
      .fullScreenCover(isPresented: $showingCamera) {
        // The photo goes straight into the message; it isn't saved to the photo library.
        CameraPicker { data in
          showingCamera = false
          if let data {
            Task { await chat.attachImage(data) }
          }
        }
        .ignoresSafeArea()
      }
    #endif
    .onChange(of: photoSelection) {
      guard let item = photoSelection else { return }
      photoSelection = nil
      Task {
        if let data = try? await item.loadTransferable(type: Data.self) {
          await chat.attachImage(data)
        } else {
          chat.alertMessage = "That photo couldn't be loaded."
        }
      }
    }
  }

  @ViewBuilder
  private var pendingPhoto: some View {
    if let image = chat.pendingImage {
      HStack(alignment: .top) {
        Image(image.preview, scale: 1, label: Text("Photo to send"))
          .resizable()
          .scaledToFill()
          .frame(width: 64, height: 64)
          .clipShape(RoundedRectangle(cornerRadius: 8))
          .onTapGesture { onShowPhoto(image.preview) }
          .accessibilityAddTraits(.isButton)
          .accessibilityHint("Shows the photo full screen")
        Button("Remove image", systemImage: "xmark.circle.fill") { chat.removePendingImage() }
          .labelStyle(.iconOnly)
          .foregroundStyle(.secondary)
      }
    } else if chat.isPreparingImage {
      ProgressView()
        .frame(height: 64)
    }
  }

  private var controls: some View {
    HStack(alignment: .bottom, spacing: 8) {
      webSearchButton
      if chat.supportsImages { photoButton }

      TextField("Message", text: $chat.draft, axis: .vertical)
        .lineLimit(1...5)
        .textFieldStyle(.roundedBorder)
        .focused($isInputFocused)

      sendButton
    }
  }

  private var webSearchButton: some View {
    Button {
      if chat.hasSearchKey {
        chat.setWebSearch(!chat.webSearchOn)
      } else {
        onOpenSettings()
      }
    } label: {
      // Drawn on the same title-size circle as Send, so every button in the row matches in height.
      Image(systemName: "circle.fill")
        .font(.title)
        .foregroundStyle(
          chat.webSearchOn ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.secondary.opacity(0.2))
        )
        .overlay {
          Image(systemName: "globe")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(
              chat.webSearchOn ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
        }
    }
    .accessibilityLabel("Web search")
    .accessibilityValue(chat.webSearchOn ? "On" : "Off")
    .accessibilityHint(chat.isOffline ? "Unavailable while the internet connection is offline" : "")
    .disabled(chat.isGenerating || chat.isOffline)
  }

  private var photoButton: some View {
    Menu {
      #if canImport(UIKit)
        if CameraPicker.isAvailable {
          Button("Take Photo", systemImage: "camera") { showingCamera = true }
        }
      #endif
      Button("Choose from Library", systemImage: "photo.on.rectangle") { showingPhotoLibrary = true }
    } label: {
      Image(systemName: "circle.fill")
        .font(.title)
        .foregroundStyle(Color.secondary.opacity(0.2))
        .overlay {
          Image(systemName: "camera")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.secondary)
        }
    }
    .accessibilityLabel("Add photo")
    .disabled(chat.isGenerating || chat.isPreparingImage)
  }

  /// Stop while a reply is coming, a red stop button while listening, the microphone when there's
  /// nothing to send, and Send otherwise.
  @ViewBuilder
  private var sendButton: some View {
    if chat.isGenerating {
      Button("Stop", systemImage: "stop.circle.fill") { chat.stop() }
        .labelStyle(.iconOnly)
        .font(.title)
        .disabled(chat.isStopping)
    } else if chat.speechInput.isActive {
      Button {
        chat.toggleDictation()
      } label: {
        Image(systemName: "stop.circle.fill")
          .font(.title)
          .foregroundStyle(.red)
          .symbolEffect(.pulse, isActive: chat.speechInput.state == .listening)
      }
      .accessibilityLabel("Stop listening")
    } else if chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && chat.pendingImage == nil
    {
      Button {
        chat.toggleDictation()
      } label: {
        Image(systemName: "mic.circle.fill")
          .font(.title)
      }
      .accessibilityLabel("Talk")
      .accessibilityHint("Speech is typed into the message field on this iPhone")
      .disabled(chat.loadState != .ready || chat.isPreparingImage)
    } else {
      Button("Send", systemImage: "arrow.up.circle.fill") { chat.send() }
        .labelStyle(.iconOnly)
        .font(.title)
        .disabled(!chat.canSend)
    }
  }

  @ViewBuilder
  private var statusLine: some View {
    let parts = [
      chat.speechInput.state == .listening ? "Listening… your voice stays on this iPhone" : nil,
      chat.replyLocationLabel,
      chat.isOffline
        ? "Internet connection is offline · web search unavailable"
        : (chat.webSearchOn ? "Web search on" : nil),
      chat.contextTokens.flatMap { used in
        chat.modelDetails.map { "Context: \(used.formatted()) / \($0.contextSize.formatted()) tokens" }
      },
    ].compactMap { $0 }

    if !parts.isEmpty {
      Text(parts.joined(separator: " · "))
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
  }
}
