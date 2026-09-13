import SwiftUI

/// A row of choices with one of them chosen — the segmented control, drawn here rather than
/// borrowed from UIKit, whose own keeps its thin height however tall a frame it is given. The
/// chosen segment is a raised tile that slides to whichever is tapped.
struct SegmentedControl<Option: Hashable & Identifiable>: View {
  let options: [Option]
  @Binding var selection: Option
  let label: (Option) -> String

  @Namespace private var thumb

  init(_ options: [Option], selection: Binding<Option>, label: @escaping (Option) -> String) {
    self.options = options
    _selection = selection
    self.label = label
  }

  var body: some View {
    HStack(spacing: 0) {
      ForEach(options) { option in
        let selected = option == selection
        Button {
          withAnimation(.snappy(duration: 0.22)) { selection = option }
        } label: {
          Text(label(option))
            .font(.subheadline.weight(selected ? .semibold : .medium))
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
              if selected {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                  .fill(Self.tile)
                  .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                  .matchedGeometryEffect(id: "tile", in: thumb)
              }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
      }
    }
    .padding(3)
    .frame(height: ChatStyle.inlineControl)
    .background(
      Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
  }

  /// The raised tile: the page's own white in light, and a step up from the track in dark.
  private static var tile: Color {
    ChatStyle.adaptive(light: Color(.systemBackground), dark: Color(.tertiarySystemBackground))
  }
}
