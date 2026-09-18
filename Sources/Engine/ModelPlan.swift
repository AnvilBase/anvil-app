import Foundation

/// What Anvil offers, as the two things a person chooses between rather than the files behind them:
/// Anvil Core, free and the default, and Anvil Pro — the unrestricted model and the one that makes
/// pictures, gathered into one thing that arrives together and goes together.
///
/// The catalog still publishes a model per file, because a file is what gets downloaded, checked
/// and loaded. This is the reading of that list every screen uses: a free model stands for itself,
/// and everything behind the paywall is one Anvil Pro. Adding a third Pro model to the catalog
/// therefore adds nothing to the screens — it joins the plan.
struct ModelPlan: Identifiable, Hashable, Sendable {
  /// `anvil-pro` for the bundle; a free model's own catalog id otherwise.
  let id: String
  let name: String
  /// The line under the name: what this is, in a few words.
  let summary: String
  let isPro: Bool
  /// The files the plan installs, in the order they have to arrive: the model to chat with first,
  /// because the one that makes pictures only works beside a chat.
  let models: [CatalogModel]

  static let proID = "anvil-pro"
  static let proName = "Anvil Pro"

  /// The catalog read as plans: each free model as itself, and every Pro model as one Anvil Pro.
  static func plans(from catalog: [CatalogModel]) -> [ModelPlan] {
    var plans: [ModelPlan] = []
    var proModels: [CatalogModel] = []
    for model in catalog {
      if model.isPro {
        proModels.append(model)
      } else {
        plans.append(
          ModelPlan(
            id: model.id, name: model.name, summary: model.summary, isPro: false, models: [model]))
      }
    }
    guard !proModels.isEmpty else { return plans }
    plans.append(
      ModelPlan(
        id: proID,
        name: proName,
        summary: summary(for: proModels),
        isPro: true,
        // Text before image: the picture model is installed beside a model to chat with, never
        // before one.
        models: proModels.sorted { !$0.isImage && $1.isImage }))
    return plans
  }

  /// What Pro is, from what the catalog actually publishes. With the whole of it published — the
  /// model to chat with and the one that makes pictures — this is the line Pro is sold in; a
  /// catalog carrying only half of Pro says the half it has rather than promising the other.
  private static func summary(for proModels: [CatalogModel]) -> String {
    let unrestricted = proModels.contains { !$0.isImage }
    let pictures = proModels.contains(where: \.isImage)
    switch (unrestricted, pictures) {
    case (true, true): return "Thinks harder, less refusals, generates pictures"
    case (true, false): return "Unrestricted. Answers without refusing"
    case (false, true): return "Makes pictures from words"
    case (false, false): return proModels.first?.summary ?? ""
    }
  }

  /// The models there is actually something to download for.
  var publishedModels: [CatalogModel] { models.filter { !$0.isComingSoon } }

  /// The model the chat runs on when this plan is the one in use, once there is one: a model the
  /// catalog has only announced is not something anyone can chat with yet, so a plan whose chat
  /// model is still unpublished has none — and the screens, which won't install a picture model
  /// without something to chat with, need to know that.
  var textModel: CatalogModel? { publishedModels.first { !$0.isImage } }
  /// The model that makes pictures beside it, if the plan has one to download.
  var imageModel: CatalogModel? { publishedModels.first(where: \.isImage) }

  /// Nothing to download: every model in the plan is announced and not published yet.
  var isComingSoon: Bool { publishedModels.isEmpty }

  /// The plan the catalog recommends — Anvil Core — which a new install runs on.
  var isRecommended: Bool { models.contains(where: \.isRecommended) }

  /// Everything the plan costs in space, added up. Two files is two files; what matters before
  /// pressing Download is the total.
  var sizeBytes: Int64 { publishedModels.reduce(0) { $0 + $1.sizeBytes } }

  var formattedSize: String {
    ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
  }

  /// How big a model this is, which is the chat model's number: the picture model is sized in
  /// gigabytes on disk, not in parameters anyone compares.
  var parameters: String? { textModel?.parameters }

  /// Whether this file is one of the plan's.
  func contains(_ model: CatalogModel) -> Bool { models.contains { $0.id == model.id } }

  /// Whether the plan is more than one file, which is when the files are worth listing by name:
  /// one file is the plan itself; two is two things arriving as one, and whoever presses Download
  /// should see both and know which is which.
  var listsFiles: Bool { publishedModels.count > 1 }

  /// What a file of the plan is for, in a sentence: "Anvil Raw, the chat model".
  static func role(of model: CatalogModel) -> String {
    model.isImage ? "the picture model" : "the chat model"
  }

  /// The same, as a label beside the name: "Chat model", "Picture model".
  static func roleTitle(of model: CatalogModel) -> String {
    model.isImage ? "Picture model" : "Chat model"
  }
}
