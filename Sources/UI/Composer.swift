import PhotosUI
import SwiftUI

#if canImport(UIKit)
  import UIKit
#endif

/// The capsule at the bottom of the chat. One line of message sits between the buttons — what you
/// can attach and whether the web is in play on the left, the microphone and the round button that
/// sends or stops on the right. When the message outgrows that line the buttons step down to a row
/// of their own and the message takes the full width above them. What you're editing, the photo or
/// file waiting to be sent, and the ways to attach one sit above the capsule.
///
/// The field never moves. An earlier version moved it — between the buttons, then to a row of its
/// own — which meant SwiftUI building a second field and throwing the first away, and the keyboard
/// went down with it on the very keystroke that reached a second line. So the field keeps one slot
/// in the hierarchy and it is the buttons that come and go around it: they carry no state and can
/// be rebuilt as often as they like. Whether the message has outgrown the line is measured from the
/// text itself against the width the line has, not from how the field happened to lay out, so the
/// two arrangements can't argue with each other and flicker. The measuring is done in the same
/// pass as the keystroke, by asking the font directly: an earlier version laid the text out
/// off-screen and read its width back, which arrived one pass late, so the field wrapped on the
/// line for a frame before the buttons stepped down under it — the very flicker this is for.
struct Composer: View {
  @Environment(\.theme) private var theme
  @Bindable var chat: ChatModel
  @FocusState.Binding var isInputFocused: Bool
  let onShowPhoto: (CGImage) -> Void

  @State private var photoSelection: PhotosPickerItem?
  @State private var showingCamera = false
  @State private var showingPhotoLibrary = false
  @State private var showingFiles = false
  /// The row of ways to attach something, up above the capsule while the plus is open.
  @State private var showingAttachOptions = false

  /// The room the line between the buttons has for the message, and the room the whole capsule
  /// has once the buttons have stepped down. The first is remembered from the last time the line
  /// was there, which is what lets the message come back down onto it once it is short enough.
  @State private var lineWidth: CGFloat = 0
  @State private var fullWidth: CGFloat = 0

  /// The size the text is set at, so the draft is measured with the font it is drawn in.
  @Environment(\.dynamicTypeSize) private var typeSize

  /// Whether the message has outgrown the line: a line break, or wider than the room it has.
  /// Judged a little early — a few points before the text would actually wrap — so the field is
  /// never caught wrapping on the line, which would be the one frame the eye reads as a glitch.
  private var isStacked: Bool {
    chat.draft.contains("\n")
      || (lineWidth > 0 && DraftMetrics.unwrappedWidth(of: chat.draft, at: typeSize) > lineWidth - 12)
  }

  /// How many lines the message takes in the room it currently has. It changes only when a line
  /// is gained or lost, so the capsule's growth animates on those keystrokes and no others.
  private var lineCount: Int {
    let room = isStacked ? fullWidth - 16 : lineWidth
    guard room > 0 else { return 1 }
    return DraftMetrics.lineCount(of: chat.draft, in: room, at: typeSize)
  }

  /// A fixed radius rather than a true Capsule, whose ends would swell into half-circles as the
  /// field grows.
  private var containerShape: RoundedRectangle {
    RoundedRectangle(cornerRadius: ChatStyle.composerCorner, style: .continuous)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if chat.editingMessageID != nil { editingBanner }
      pendingPhoto
      pendingFile
      if showingAttachOptions { attachOptions }
      inputCapsule
    }
    .padding(.horizontal, 16)
    .padding(.bottom, 10)
    // Whatever was being chosen is over once the message has gone, and going back to the words —
    // tapping into the field, or typing — puts the row away too.
    .onChange(of: chat.isGenerating) { _, generating in
      if generating { setAttachOptions(false) }
    }
    .onChange(of: isInputFocused) { _, focused in
      if focused { setAttachOptions(false) }
    }
    .onChange(of: chat.draft) { setAttachOptions(false) }
    // Swiping down anywhere on the composer puts the keyboard away, the same way dragging the
    // conversation does. Simultaneous, so the field keeps its own taps and text selection.
    .simultaneousGesture(swipeDownToDismiss)
    .photosPicker(isPresented: $showingPhotoLibrary, selection: $photoSelection, matching: .images)
    .fileImporter(isPresented: $showingFiles, allowedContentTypes: FileReading.types) { result in
      switch result {
      case .success(let url): Task { await chat.attachFile(url) }
      case .failure(let error): chat.alertMessage = error.localizedDescription
      }
    }
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

  /// One word and the mark that goes with it. What editing does — replacing the message and
  /// everything after it — is what the field full of your own words already says.
  private var editingBanner: some View {
    HStack(spacing: 6) {
      Label("Editing", systemImage: "pencil")
        .font(.subheadline)
        .foregroundStyle(.secondary)
      Spacer(minLength: 8)
      Button { chat.cancelEditing() } label: {
        Image(systemName: "xmark")
          .font(.system(size: 15, weight: .semibold))
          .frame(width: ChatStyle.smallControl, height: ChatStyle.smallControl)
          .liquidGlass(in: Circle(), interactive: true)
          .contentShape(Circle())
      }
      .buttonStyle(.plain)
      .foregroundStyle(.primary)
      .accessibilityLabel("Stop editing")
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

  /// The file waiting to go: its name on a small card, and the way to take it off again.
  @ViewBuilder
  private var pendingFile: some View {
    if let file = chat.pendingFile {
      HStack(spacing: 8) {
        HStack(spacing: 8) {
          Image(systemName: "doc.text")
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(.secondary)
          VStack(alignment: .leading, spacing: 1) {
            Text(file.name)
              .font(.subheadline.weight(.medium))
              .lineLimit(1)
            if file.isTruncated {
              Text("Beginning only; the file is longer")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          Button("Remove file", systemImage: "xmark.circle.fill") { chat.removePendingFile() }
            .labelStyle(.iconOnly)
            .font(.system(size: 18))
            .foregroundStyle(.secondary)
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .liquidGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(theme.hairline, lineWidth: 0.5))
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 4)
      .padding(.top, 2)
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
      .padding(.vertical, 6)
      // Never shorter than the buttons, on the line or off it: a line of text sits level with
      // them, and a message that has stepped over them keeps the same height for its first line
      // and grows from there. The same shape in both arrangements, so moving between them changes
      // where the field is and how wide, and nothing about how tall — one thing to animate, not
      // three.
      .frame(minHeight: ChatStyle.inlineControl)
  }

  // MARK: - The controls around it

  /// The buttons on the left, as a pair: what you can attach, and whether the web is in play.
  private var leadingButtons: some View {
    HStack(spacing: 0) {
      addButton
      // Gone rather than greyed out when there is no connection: a switch that cannot be moved is
      // something to wonder about, and web search without the web isn't a setting, it is nothing.
      // What it was set to is kept in the settings file, not in the button, so it comes back the
      // way it was left.
      if !chat.isOffline { webSearchButton }
      if chat.speechInput.state == .listening {
        SpeechWave(level: CGFloat(chat.speechInput.level))
          .padding(.leading, 4)
          .transition(.opacity.combined(with: .scale(scale: 0.6, anchor: .leading)))
      }
    }
  }

  /// The leading pair are drawn a little narrower than the round buttons on the right, so the two
  /// glyphs read as neighbours rather than as two stops along the row.
  private static let leadingControl = ChatStyle.inlineControl - 6

  private var inputCapsule: some View {
    LiquidGlassGroup {
      // One layout holds the three pieces — the buttons on the left, the field, the buttons on the
      // right — and only moves them. Nothing is inserted or removed when the message outgrows the
      // line, which is what lets the change animate: the buttons slide down to their own row and
      // the field widens over them, instead of one arrangement popping into the other.
      ComposerLayout(stacked: isStacked, spacing: 6, rowSpacing: 8) {
        leadingButtons
        messageField
          .measuringWidth { if !isStacked { lineWidth = $0 - 16 } }
        HStack(spacing: 6) { trailingButtons }
      }
      .measuringWidth { fullWidth = $0 }
      .animation(.snappy(duration: 0.22), value: chat.speechInput.state)
      .animation(.snappy(duration: 0.28), value: chat.isOffline)
      .padding(9)
      .liquidGlass(in: containerShape)
      .overlay(containerShape.strokeBorder(theme.hairline, lineWidth: 0.5))
      // Smooth rather than snappy for the two ways the capsule changes shape under your thumb:
      // the buttons stepping down and back up, and a line gained or lost. Nothing should
      // overshoot while you are typing into it.
      .animation(.smooth(duration: 0.28), value: isStacked)
      .animation(.smooth(duration: 0.2), value: lineCount)
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

  /// The plus: it opens and closes the row of ways to attach something, up above the capsule. It
  /// used to be a menu, which iOS put wherever it liked — over the capsule as often as not — and
  /// which hid the photo options whenever the loaded model couldn't see photos. The row is always
  /// the same three things, and it is always where the plus is pointing.
  private var addButton: some View {
    Button {
      setAttachOptions(!showingAttachOptions)
    } label: {
      Image(systemName: "plus")
        .font(.system(size: ChatStyle.inlineControlGlyph, weight: .medium))
        .foregroundStyle(.primary)
        // Turned to a cross while the row is up: the same button, now the way to put it away.
        .rotationEffect(.degrees(showingAttachOptions ? 45 : 0))
        .frame(width: Self.leadingControl, height: ChatStyle.inlineControl)
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Attach")
    .accessibilityValue(showingAttachOptions ? "Open" : "Closed")
    .disabled(chat.isGenerating || chat.isPreparingImage)
  }

  /// Opens or closes the row, animated. The animation is asked for here, on the change, rather
  /// than hung on the composer as a whole: an implicit animation over the whole stack redrew the
  /// capsule's glass mid-flight, and glass caught mid-redraw comes out black.
  private func setAttachOptions(_ open: Bool) {
    guard open != showingAttachOptions else { return }
    withAnimation(.spring(duration: 0.32, bounce: 0.18)) { showingAttachOptions = open }
  }

  /// Everything you can put into a message, as a small pane above the capsule, over the plus that
  /// opened it: Capture, Photo, File, one under the other the way a menu lists them. Always all
  /// three, whatever model is loaded — a photo can always be attached, and what the model makes
  /// of it is the model's business. Choosing one puts the pane away and opens the picker.
  ///
  /// A material pane, not glass: it stands above the capsule and never over it, and material
  /// over glass draws cleanly where glass over glass came out black. It springs up from its
  /// bottom-left corner, where the plus is, and goes back the same way.
  private var attachOptions: some View {
    VStack(spacing: 0) {
      #if canImport(UIKit)
        if CameraPicker.isAvailable {
          attachOption("Capture", systemImage: "camera") { showingCamera = true }
          Divider()
        }
      #endif
      attachOption("Photo", systemImage: "photo") { showingPhotoLibrary = true }
      Divider()
      attachOption("File", systemImage: "doc") { showingFiles = true }
    }
    .frame(width: 190)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .strokeBorder(theme.hairline, lineWidth: 0.5))
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.leading, 4)
    .transition(.scale(scale: 0.85, anchor: .bottomLeading).combined(with: .opacity))
  }

  private func attachOption(
    _ title: String, systemImage: String, action: @escaping () -> Void
  ) -> some View {
    Button {
      setAttachOptions(false)
      action()
    } label: {
      HStack(spacing: 12) {
        Image(systemName: systemImage)
          .font(.body.weight(.medium))
          .frame(width: 22)
        Text(title)
          .font(.body)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(.primary)
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
      chat.setWebSearch(!chat.webSearchOn)
    } label: {
      Image(systemName: "globe")
        .font(
          .system(
            size: ChatStyle.inlineControlGlyph, weight: chat.webSearchOn ? .semibold : .medium)
        )
        .foregroundStyle(webSearchGlyph)
        .frame(width: Self.leadingControl, height: ChatStyle.inlineControl)
        .background(
          Color.primary.opacity(chat.webSearchOn ? 0.12 : 0),
          in: Circle()
        )
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .animation(.snappy(duration: 0.2), value: chat.webSearchOn)
    // Out with the connection and back in with it, rather than appearing and disappearing.
    .transition(.opacity.combined(with: .scale(scale: 0.7)))
    .accessibilityLabel("Web search")
    .accessibilityValue(chat.webSearchOn ? "On" : "Off")
    .disabled(chat.isGenerating || chat.loadState != .ready)
  }

  /// Full strength either way — the wash behind it is what says it's on — and faded while no model
  /// is loaded, the same as the plus beside it: two buttons that are waiting for the same thing
  /// should look like it together.
  private var webSearchGlyph: AnyShapeStyle {
    chat.loadState == .ready ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary)
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
        circleButton("Send", systemImage: "arrow.up", dimmed: !chat.canSend, action: chat.sendOrSayWhyNot)
          .transition(.scale.combined(with: .opacity))
      }
    }
  }

  private var hasSomethingToSend: Bool {
    !chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chat.pendingImage != nil
      || chat.pendingFile != nil
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
    .accessibilityLabel(micLabel)
    .accessibilityHint("Speech is typed into the message field on this iPhone")
  }

  /// In voice mode the stop square closes voice mode, so it says so.
  private var micLabel: String {
    guard chat.speechInput.isActive else { return "Talk" }
    return chat.voiceModeOn ? "End voice mode" : "Stop listening"
  }

  /// The filled ones, drawn smaller than the bare glyphs beside them. A circle of solid colour
  /// carries to the eye in a way an outlined microphone doesn't, so at the size the others are set
  /// to it was the heaviest thing on the row by some way. Six points off puts it back in the row.
  private static let filledControl = ChatStyle.inlineControl - 6

  private func circleButton(
    _ title: String, systemImage: String, tint: Color? = nil, disabled: Bool = false,
    dimmed: Bool = false, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.system(size: ChatStyle.inlineControlGlyph - 3, weight: .semibold))
        .foregroundStyle(tint == nil ? theme.sendGlyph : .white)
        .frame(width: Self.filledControl, height: Self.filledControl)
        .background(tint ?? theme.sendFill, in: Circle())
        .frame(width: ChatStyle.inlineControl, height: ChatStyle.inlineControl)
        .contentShape(Circle())
        // `dimmed` looks like `disabled` and isn't: Send waits for the model rather than dying
        // with it, and a press while it waits is how you find out what it is waiting for.
        .opacity(disabled || dimmed ? 0.35 : 1)
    }
    .buttonStyle(.plain)
    .disabled(disabled)
    .accessibilityLabel(title)
  }

}


/// The draft measured the way the field will draw it, in the same pass as the keystroke.
///
/// The field is `.body` at whatever size the environment has set, and UIKit is asked for that
/// same font, so what is measured here is what the field lays out. The answer is a few points
/// off at most, which is why `Composer` leaves a margin rather than trusting it to the point.
private enum DraftMetrics {
  /// The width the message would take on one line.
  static func unwrappedWidth(of draft: String, at size: DynamicTypeSize) -> CGFloat {
    #if canImport(UIKit)
      guard !draft.isEmpty else { return 0 }
      return (draft as NSString).size(withAttributes: [.font: font(at: size)]).width.rounded(.up)
    #else
      return 0
    #endif
  }

  /// How many lines the message takes wrapped to `width`. Never less than one.
  static func lineCount(of draft: String, in width: CGFloat, at size: DynamicTypeSize) -> Int {
    #if canImport(UIKit)
      guard !draft.isEmpty else { return 1 }
      let font = font(at: size)
      // A trailing line break is a line of its own, which `boundingRect` does not count.
      let measured = draft.hasSuffix("\n") ? draft + " " : draft
      let bounds = (measured as NSString).boundingRect(
        with: CGSize(width: width, height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        attributes: [.font: font], context: nil)
      return max(1, Int((bounds.height / font.lineHeight).rounded()))
    #else
      return max(1, draft.components(separatedBy: "\n").count)
    #endif
  }

  #if canImport(UIKit)
    private static func font(at size: DynamicTypeSize) -> UIFont {
      UIFont.preferredFont(
        forTextStyle: .body,
        compatibleWith: UITraitCollection(preferredContentSizeCategory: size.contentSizeCategory))
    }
  #endif
}

#if canImport(UIKit)
  extension DynamicTypeSize {
    /// The same size as UIKit names it. SwiftUI converts the other way but not this one.
    fileprivate var contentSizeCategory: UIContentSizeCategory {
      switch self {
      case .xSmall: .extraSmall
      case .small: .small
      case .medium: .medium
      case .large: .large
      case .xLarge: .extraLarge
      case .xxLarge: .extraExtraLarge
      case .xxxLarge: .extraExtraExtraLarge
      case .accessibility1: .accessibilityMedium
      case .accessibility2: .accessibilityLarge
      case .accessibility3: .accessibilityExtraLarge
      case .accessibility4: .accessibilityExtraExtraLarge
      case .accessibility5: .accessibilityExtraExtraExtraLarge
      @unknown default: .large
      }
    }
  }
#endif

/// The composer's three pieces — the buttons on the left, the field, the buttons on the right —
/// on one line, or with the field across the top and the buttons in a row beneath it. The same
/// three views either way, only placed differently, so switching is a change of position that
/// SwiftUI animates rather than a change of hierarchy that it can't.
private struct ComposerLayout: Layout {
  var stacked: Bool
  var spacing: CGFloat
  var rowSpacing: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard subviews.count == 3 else { return .zero }
    let width = proposal.width ?? 0
    let leading = subviews[0].sizeThatFits(.unspecified)
    let trailing = subviews[2].sizeThatFits(.unspecified)
    if stacked {
      let field = subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil))
      let row = max(leading.height, trailing.height)
      return CGSize(width: width, height: field.height + rowSpacing + row)
    } else {
      let fieldWidth = max(0, width - leading.width - trailing.width - 2 * spacing)
      let field = subviews[1].sizeThatFits(ProposedViewSize(width: fieldWidth, height: nil))
      return CGSize(width: width, height: max(field.height, leading.height, trailing.height))
    }
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    guard subviews.count == 3 else { return }
    let leading = subviews[0].sizeThatFits(.unspecified)
    let trailing = subviews[2].sizeThatFits(.unspecified)
    if stacked {
      let field = subviews[1].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
      subviews[1].place(
        at: CGPoint(x: bounds.minX, y: bounds.minY), anchor: .topLeading,
        proposal: ProposedViewSize(width: bounds.width, height: field.height))
      let rowY = bounds.minY + field.height + rowSpacing
      let row = max(leading.height, trailing.height)
      subviews[0].place(
        at: CGPoint(x: bounds.minX, y: rowY + row / 2), anchor: .leading,
        proposal: ProposedViewSize(leading))
      subviews[2].place(
        at: CGPoint(x: bounds.maxX, y: rowY + row / 2), anchor: .trailing,
        proposal: ProposedViewSize(trailing))
    } else {
      let fieldWidth = max(0, bounds.width - leading.width - trailing.width - 2 * spacing)
      let field = subviews[1].sizeThatFits(ProposedViewSize(width: fieldWidth, height: nil))
      let midY = bounds.midY
      subviews[0].place(
        at: CGPoint(x: bounds.minX, y: midY), anchor: .leading, proposal: ProposedViewSize(leading))
      subviews[1].place(
        at: CGPoint(x: bounds.minX + leading.width + spacing, y: midY), anchor: .leading,
        proposal: ProposedViewSize(width: fieldWidth, height: field.height))
      subviews[2].place(
        at: CGPoint(x: bounds.maxX, y: midY), anchor: .trailing, proposal: ProposedViewSize(trailing))
    }
  }
}
