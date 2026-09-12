import SwiftUI

/// Saved memories: add one by hand, swipe to delete, or clear them all.
struct MemoryScreen: View {
  let memory: MemoryStore

  @State private var newMemory = ""
  @State private var confirmingDeleteAll = false

  var body: some View {
    List {
      Section {
        TextField("Add something to remember", text: $newMemory, axis: .vertical)
        Button("Add", action: add)
          .disabled(newMemory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      } footer: {
        Text("For example: \"I'm vegetarian\" or \"I'm learning Swift.\"")
      }

      Section {
        if memory.items.isEmpty {
          Text("No memories yet. Ask \(AppFlavor.appName) to remember something, or add it above.")
            .foregroundStyle(.secondary)
        }
        ForEach(memory.items) { item in
          VStack(alignment: .leading, spacing: 2) {
            Text(item.text)
            Text(item.createdAt.formatted(date: .abbreviated, time: .omitted))
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .onDelete { memory.delete(at: $0) }
      } header: {
        Text("Saved")
      } footer: {
        Text("Swipe left on a memory to delete it. Memories are stored only on this iPhone.")
      }

      if !memory.items.isEmpty {
        Section {
          Button("Delete all memories", role: .destructive) { confirmingDeleteAll = true }
        }
      }
    }
    .navigationTitle("Memory")
    .confirmationDialog(
      "Delete all memories?", isPresented: $confirmingDeleteAll, titleVisibility: .visible
    ) {
      Button("Delete all memories", role: .destructive) { memory.deleteAll() }
    } message: {
      Text("This can't be undone.")
    }
  }

  private func add() {
    memory.add(newMemory)
    newMemory = ""
  }
}
