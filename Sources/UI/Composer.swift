import PhotosUI
import SwiftUI

#if canImport(UIKit)
  import UIKit
#endif

/// The capsule at the bottom of the chat: what you're typing across the top, and everything you can
/// do to it on the row underneath — what you can attach, whether the web is in play, and the round
/// button that talks, sends, or stops. What you're editing and the photo waiting to be sent sit
/// above the capsule, so its own shape never changes except to grow with the message.
///
/// One arrangement, always. The field used to share a row with the buttons until the message
/// outgrew it and then move to a row of its own, which meant SwiftUI building a second field and
/// throwing the first away — and the keyboard went down with it, on the very keystroke that needed
/// it, every time a message reached a second line.
struct Composer: View {
  @Bindable var chat: ChatModel
  @FocusState.Binding var isInputFocused: Bool
  let onShowPhoto: (CGImage) -> Void

  @State private var photoSelection: PhotosPickerItem?
  @State private var showingCamera = false
  @State private var showingPhotoLibrary = false

  /// A fixed radius rather than a true Capsule, whose ends would swell into half-circles as the
  /// field grows.
  private var containerShape: RoundedRectangle {
    RoundedRectangle(cornerRadius: ChatStyle.composerCorner, style: .continuous)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if chat.editingMessageID != nil { editingBanner }
      pendingPhoto
      inputCapsule
    }
    .padding(.horizontal, 12)
    .padding(.bottom, 8)
    // Swiping down anywhere on the composer puts the keyboard away, the same way dragging the
    // conversation does. Simultaneous, so the field keeps its own taps and text selection.
    .simultaneousGesture(swipeDownToDismiss)
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
      .font(.subheadline)
      .foregroundStyle(.secondary)
      Spacer(minLength: 8)
      Button("Cancel") { chat.cancelEditing() }
        .font(.subheadline.weight(.medium))
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
          .frame(width: 64, height: 64)
          .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
          .onTapGesture { onShowPhoto(image.preview) }
          .accessibilityAddTraits(.isButton)
          .accessibilityHint("Shows the photo full screen")
          .overlay(alignment: .topTrailing) {
            Button("Remove image", systemImage: "xmark.circle.fill") { chat.removePendingImage() }
              .labelStyle(.iconOnly)
              .font(.system(size: ChatStyle.inlineControlGlyph))
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
          .frame(width: 64, height: 64)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 4)
    }
  }

  // MARK: - The field

  private var messageField: some View {
    TextField("Ask Anvil", text: $chat.draft, axis: .vertical)
      .textFieldStyle(.plain)
      .lineLimit(1...8)
      // What you type is the size it will be once it has been sent.
      .font(.body)
      .focused($isInputFocused)
      .padding(.horizontal, 8)
      .padding(.top, 8)
      .padding(.bottom, 2)
  }

  // MARK: - The controls under it

  private var inputCapsule: some View {
    LiquidGlassGroup {
      VStack(alignment: .leading, spacing: 10) {
        messageField
        HStack(spacing: 6) {
          addButton
          webSearchButton
          Spacer(minLength: 0)
          trailingButtons
        }
      }
      .padding(8)
      .liquidGlass(in: containerShape)
      .overlay(containerShape.strokeBorder(ChatStyle.hairline, lineWidth: 0.5))
      .animation(.snappy(duration: 0.18), value: hasSomethingToSend)
      // Only on the empty-to-typing boundary, which is sending and starting again — not on every
      // keystroke that grows the field a line.
      .animation(ChatStyle.sendMotion, value: chat.draft.isEmpty)
    }
  }

  /// Down, and meaningfully down rather than a wobble on the way to something else.
  private var swipeDownToDismiss: some Gesture {
    DragGesture(minimumDistance: 24)
      .onEnded { value in
        let down = value.translation.height
        guard down > 24, down > abs(value.translation.width) else { return }
        isInputFocused = false
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
      .font(.system(size: ChatStyle.inlineControlGlyph, weight: .medium))
      .foregroundStyle(available ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
      .frame(width: ChatStyle.inlineControl, height: ChatStyle.inlineControl)
      .contentShape(Circle())
  }

  /// Two different reasons photos are unavailable, and the difference decides what to do about it.
  private var noImagesReason: String {
    chat.settings.values.engine.imageInput
      ? "The model that's loaded can't read images. A model that can will show the photo options "
        + "here."
      : "Image input is switched off. Turn it on in Settings › Model, then Reload model."
  }

  /// A plain globe when it's off, the same globe on a soft wash of the page's own ink when it's
  /// on — not the solid fill it used to take, which is the one treatment Send has, and which made
  /// a switch that is merely set look like the button that acts. The glyph also thickens a little,
  /// so the state carries at a glance without anything on the row getting louder.
  ///
  /// The label it used to grow when switched on changed the width of the row, which nudged
  /// everything beside it.
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
      Image(systemName: "globe")
        .font(
          .system(
            size: ChatStyle.inlineControlGlyph, weight: chat.webSearchOn ? .semibold : .medium)
        )
        .foregroundStyle(webSearchGlyph)
        .frame(width: ChatStyle.inlineControl, height: ChatStyle.inlineControl)
        .background(
          Color.primary.opacity(chat.webSearchOn ? 0.12 : 0),
          in: Circle()
        )
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .animation(.snappy(duration: 0.2), value: chat.webSearchOn)
    .accessibilityLabel("Web search")
    .accessibilityValue(chat.webSearchOn ? "On" : "Off")
    .accessibilityHint(webSearchHint)
    .disabled(chat.isGenerating || chat.isOffline)
  }

  /// Full strength either way — the wash behind it is what says it's on — and faded when the
  /// build carries no key, so a globe that can't be switched on doesn't look like one that can.
  private var webSearchGlyph: AnyShapeStyle {
    chat.hasSearchKey ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary)
  }

  private var webSearchHint: String {
    if chat.isOffline { return "Unavailable while the internet connection is offline" }
    if !chat.hasSearchKey { return "This build has no Brave Search API key" }
    return ""
  }

  /// The filled circle on the right: Stop while a reply is coming, a stop square while it's
  /// listening, the microphone when there's nothing to send, and Send otherwise.
  /// The microphone stays put and Send appears beside it once there's something to send, rather
  /// than one button changing job underneath your thumb.
  @ViewBuilder
  private var trailingButtons: some View {
    if chat.isGenerating {
      circleButton("Stop", systemImage: "stop.fill", disabled: chat.isStopping) { chat.stop() }
    } else {
      micButton
      if hasSomethingToSend {
        circleButton("Send", systemImage: "arrow.up", disabled: !chat.canSend) { chat.send() }
          .transition(.scale.combined(with: .opacity))
      }
    }
  }

  private var hasSomethingToSend: Bool {
    !chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chat.pendingImage != nil
  }

  /// A plain glyph, not a filled circle — the filled circle is what marks the one button that acts.
  private var micButton: some View {
    Button { chat.toggleDictation() } label: {
      Image(systemName: chat.speechInput.isActive ? "stop.fill" : "mic.fill")
        .font(.system(size: ChatStyle.inlineControlGlyph, weight: .medium))
        .foregroundStyle(chat.speechInput.isActive ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
        .frame(width: ChatStyle.inlineControl, height: ChatStyle.inlineControl)
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .disabled(chat.loadState != .ready || chat.isPreparingImage)
    .symbolEffect(.pulse, isActive: chat.speechInput.state == .listening)
    .accessibilityLabel(chat.speechInput.isActive ? "Stop listening" : "Talk")
    .accessibilityHint("Speech is typed into the message field on this iPhone")
  }

  private func circleButton(
    _ title: String, systemImage: String, tint: Color? = nil, disabled: Bool = false,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.system(size: ChatStyle.inlineControlGlyph, weight: .semibold))
        .foregroundStyle(tint == nil ? ChatStyle.sendGlyph : .white)
        .frame(width: ChatStyle.inlineControl, height: ChatStyle.inlineControl)
        .background(tint ?? ChatStyle.sendFill, in: Circle())
        .opacity(disabled ? 0.35 : 1)
    }
    .buttonStyle(.plain)
    .disabled(disabled)
    .accessibilityLabel(title)
  }

}
