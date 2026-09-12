import PhotosUI
import SwiftUI

#if canImport(UIKit)
  import UIKit
#endif

/// The card at the bottom of the chat: what you're editing, the photo waiting to be sent, the
/// message field, and a row of controls under it — add a photo, search the web, and the one round
/// button on the right that talks, sends, or stops.
struct Composer: View {
  @Bindable var chat: ChatModel
  @FocusState.Binding var isInputFocused: Bool
  let onShowPhoto: (CGImage) -> Void

  @State private var photoSelection: PhotosPickerItem?
  @State private var showingCamera = false
  @State private var showingPhotoLibrary = false

  private var containerShape: RoundedRectangle {
    RoundedRectangle(cornerRadius: ChatStyle.composerCorner, style: .continuous)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if chat.editingMessageID != nil { editingBanner }

      LiquidGlassGroup {
        VStack(alignment: .leading, spacing: 10) {
          pendingPhoto
          messageField
          controlRow
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .liquidGlass(in: containerShape)
        .overlay(containerShape.strokeBorder(ChatStyle.hairline, lineWidth: 0.5))
      }
    }
    .padding(.horizontal, 12)
    .padding(.bottom, 8)
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

  // MARK: - Above the field

  private var editingBanner: some View {
    HStack(spacing: 6) {
      Label(
        "Editing a message — sending replaces it and everything after it", systemImage: "pencil"
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      Spacer(minLength: 8)
      Button("Cancel") { chat.cancelEditing() }
        .font(.caption.weight(.medium))
    }
    .padding(.horizontal, 14)
  }

  @ViewBuilder
  private var pendingPhoto: some View {
    if let image = chat.pendingImage {
      HStack(spacing: 8) {
        Image(image.preview, scale: 1, label: Text("Photo to send"))
          .resizable()
          .scaledToFill()
          .frame(width: 56, height: 56)
          .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
          .onTapGesture { onShowPhoto(image.preview) }
          .accessibilityAddTraits(.isButton)
          .accessibilityHint("Shows the photo full screen")
          .overlay(alignment: .topTrailing) {
            Button("Remove image", systemImage: "xmark.circle.fill") { chat.removePendingImage() }
              .labelStyle(.iconOnly)
              .font(.system(size: 17))
              .symbolRenderingMode(.palette)
              .foregroundStyle(.white, .black.opacity(0.5))
              .offset(x: 6, y: -6)
          }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 4)
      .padding(.top, 2)
    } else if chat.isPreparingImage {
      HStack {
        ProgressView()
          .frame(width: 56, height: 56)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 4)
    }
  }

  // MARK: - The field

  private var messageField: some View {
    TextField("Ask anything", text: $chat.draft, axis: .vertical)
      .textFieldStyle(.plain)
      .lineLimit(1...6)
      .font(.system(size: 17))
      .focused($isInputFocused)
      .padding(.horizontal, 6)
      .padding(.top, 2)
  }

  // MARK: - The controls under it

  private var controlRow: some View {
    HStack(spacing: 8) {
      addButton
      webSearchButton
      Spacer(minLength: 0)
      primaryButton
    }
  }

  /// Everything you can put into a message. It's always here, the way ChatGPT's plus is: a control
  /// that disappears depending on which model is loaded reads as a bug, and leaves nothing to say
  /// why photos can't be sent.
  @ViewBuilder
  private var addButton: some View {
    if chat.supportsImages {
      Menu {
        #if canImport(UIKit)
          if CameraPicker.isAvailable {
            Button("Camera", systemImage: "camera") { showingCamera = true }
          }
        #endif
        Button("Photos", systemImage: "photo.on.rectangle") { showingPhotoLibrary = true }
      } label: {
        plusLabel(available: true)
      }
      .tint(.primary)
      .accessibilityLabel("Add photo")
      .disabled(chat.isGenerating || chat.isPreparingImage)
    } else {
      Button { chat.alertMessage = noImagesReason } label: { plusLabel(available: false) }
        .buttonStyle(.plain)
        .accessibilityLabel("Add photo")
        .accessibilityHint("Unavailable with the model that's loaded")
    }
  }

  private func plusLabel(available: Bool) -> some View {
    Image(systemName: "plus")
      .font(.system(size: 18, weight: .medium))
      .foregroundStyle(available ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
      .frame(width: 34, height: 34)
      .contentShape(Circle())
  }

  /// Two different reasons photos are unavailable, and the difference decides what to do about it.
  private var noImagesReason: String {
    chat.settings.values.engine.imageInput
      ? "The model that's loaded can't read images. A model that can will show the photo options "
        + "here."
      : "Image input is switched off. Turn it on in Settings › Model, then Reload model."
  }

  /// A plain globe when it's off, a tinted pill that says what it does when it's on.
  private var webSearchButton: some View {
    Button {
      guard chat.hasSearchKey else {
        // Opening Settings here looked like the button was mis-wired, because Settings can't fix it
        // either: the key is compiled in, so the only remedy is a rebuild. Say that instead.
        chat.alertMessage =
          "Web search needs a Brave Search API key, and this build has none. Put one in "
          + "Config/Local.xcconfig as ANVIL_BRAVE_API_KEY and build again. Everything else works "
          + "without it."
        return
      }
      chat.setWebSearch(!chat.webSearchOn)
    } label: {
      HStack(spacing: 5) {
        Image(systemName: "globe")
          .font(.system(size: 16, weight: .medium))
        if chat.webSearchOn {
          Text("Search")
            .font(.system(size: 15, weight: .medium))
        }
      }
      .foregroundStyle(webSearchTint)
      .padding(.horizontal, chat.webSearchOn ? 12 : 0)
      .frame(minWidth: 34, minHeight: 34)
      .background(
        chat.webSearchOn ? AnyShapeStyle(.tint.opacity(0.14)) : AnyShapeStyle(.clear),
        in: Capsule()
      )
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .animation(.snappy(duration: 0.2), value: chat.webSearchOn)
    .accessibilityLabel("Web search")
    .accessibilityValue(chat.webSearchOn ? "On" : "Off")
    .accessibilityHint(webSearchHint)
    .disabled(chat.isGenerating || chat.isOffline)
  }

  /// Tinted when on, plain when off, and faded when the build carries no key — so a globe that
  /// can't be switched on doesn't look like one that can.
  private var webSearchTint: AnyShapeStyle {
    if chat.webSearchOn { return AnyShapeStyle(.tint) }
    return chat.hasSearchKey ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary)
  }

  private var webSearchHint: String {
    if chat.isOffline { return "Unavailable while the internet connection is offline" }
    if !chat.hasSearchKey { return "This build has no Brave Search API key" }
    return ""
  }

  /// The filled circle on the right: Stop while a reply is coming, a stop square while it's
  /// listening, the microphone when there's nothing to send, and Send otherwise.
  @ViewBuilder
  private var primaryButton: some View {
    if chat.isGenerating {
      circleButton("Stop", systemImage: "stop.fill", disabled: chat.isStopping) { chat.stop() }
    } else if chat.speechInput.isActive {
      circleButton("Stop listening", systemImage: "stop.fill", tint: .red) {
        chat.toggleDictation()
      }
      .symbolEffect(.pulse, isActive: chat.speechInput.state == .listening)
    } else if chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && chat.pendingImage == nil
    {
      circleButton(
        "Talk", systemImage: "mic.fill",
        disabled: chat.loadState != .ready || chat.isPreparingImage
      ) {
        chat.toggleDictation()
      }
      .accessibilityHint("Speech is typed into the message field on this iPhone")
    } else {
      circleButton("Send", systemImage: "arrow.up", disabled: !chat.canSend) { chat.send() }
    }
  }

  private func circleButton(
    _ title: String, systemImage: String, tint: Color? = nil, disabled: Bool = false,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.system(size: 16, weight: .bold))
        .foregroundStyle(tint == nil ? ChatStyle.sendGlyph : .white)
        .frame(width: 34, height: 34)
        .background(tint ?? ChatStyle.sendFill, in: Circle())
        .opacity(disabled ? 0.35 : 1)
    }
    .buttonStyle(.plain)
    .disabled(disabled)
    .accessibilityLabel(title)
  }

}
