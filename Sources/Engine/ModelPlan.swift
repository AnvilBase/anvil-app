import Foundation

/// One of the things Anvil offers, the way the screens list them: Anvil Core, free and the
/// default; Anvil Pro, the unrestricted model; and the models that make pictures, Anvil Dream and
/// Anvil Dream Lite. Each is one catalog model and one download — chosen, fetched and deleted on
/// its own. The ones that need Anvil Pro wait behind the paywall until it is active.
///
/// For a while every Pro model was gathered into one Anvil Pro that arrived and went together.
/// The catalog is read one model to a plan again, and the plan keeps the shape the screens were
/// written against — a plan with a list of models — so a card or a row still shows a plan, and
/// the list is one long.
struct ModelPlan: Identifiable, Hashable, Sendable {
  /// The catalog model's own id.
  let id: String
  let name: String
  /// The line under the name: what this is, in a few words.
  let summary: String
  let isPro: Bool
  /// The files the plan installs: one.
  let models: [CatalogModel]

  init(_ model: CatalogModel) {
    id = model.id
    name = model.name
    summary = model.summary
    isPro = model.isPro
    models = [model]
  }

  /// Whether this is a model that makes pictures.
  var isImage: Bool { models.first?.isImage ?? false }

  /// Whether this phone has the memory the model needs.
  var fitsThisPhone: Bool { models.allSatisfy(\.fitsThisPhone) }
  var formattedMinimumMemory: String? { models.first?.formattedMinimumMemory }

  /// The name as it reads in a sentence: "Downloading Anvil Dream Lite".
  var sentenceName: String { name }

  /// The catalog as plans, in the catalog's order: one each.
  static func plans(from catalog: [CatalogModel]) -> [ModelPlan] {
    catalog.map(ModelPlan.init)
  }

  /// The models there is actually something to download for.
  var publishedModels: [CatalogModel] { models.filter { !$0.isComingSoon } }

  /// The model the chat runs on when this plan is the one in use, once there is one: a model the
  /// catalog has only announced is not something anyone can chat with yet. Nil for the plan that
  /// makes pictures, which the screens won't install without something to chat with.
  var textModel: CatalogModel? { publishedModels.first { !$0.isImage } }
  /// The model that makes pictures, if this plan is that one.
  var imageModel: CatalogModel? { publishedModels.first(where: \.isImage) }

  /// Nothing to download: announced and not published yet.
  var isComingSoon: Bool { publishedModels.isEmpty }

  /// The plan the catalog recommends — Anvil Core — which a new install runs on.
  var isRecommended: Bool { models.contains(where: \.isRecommended) }

  /// What the plan costs in space.
  var sizeBytes: Int64 { publishedModels.reduce(0) { $0 + $1.sizeBytes } }

  var formattedSize: String {
    ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
  }

  /// How big a model this is, the way the catalog sizes it.
  var parameters: String? { models.first?.parameters }

  /// Whether this file is one of the plan's.
  func contains(_ model: CatalogModel) -> Bool { models.contains { $0.id == model.id } }

}
