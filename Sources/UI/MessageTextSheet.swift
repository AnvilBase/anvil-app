import SwiftUI

#if canImport(UIKit)
  import UIKit

  /// Shows a message in a read-only text view so any part of it can be selected and copied.
  /// SwiftUI's Text on iOS can only copy an entire Text at once.
  struct MessageTextSheet: View {
    let text: String

    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
      NavigationStack {
        SelectableTextView(text: text)
          .ignoresSafeArea(edges: .bottom)
          .navigationTitle("Select Text")
          .navigationBarTitleDisplayMode(.inline)
          .toolbar {
            ToolbarItem(placement: .cancellationAction) {
              Button(copied ? "Copied" : "Copy All") {
                UIPasteboard.general.string = text
                copied = true
              }
            }
            ToolbarItem(placement: .confirmationAction) {
              Button("Done") { dismiss() }
            }
          }
      }
    }
  }

  private struct SelectableTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
      let view = UITextView()
      view.isEditable = false
      view.isSelectable = true
      view.font = .preferredFont(forTextStyle: .body)
      view.adjustsFontForContentSizeCategory = true
      view.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
      view.backgroundColor = .clear
      return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
      if view.text != text { view.text = text }
    }
  }
#endif
