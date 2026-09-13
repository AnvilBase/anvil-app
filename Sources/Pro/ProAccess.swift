import Foundation
import Observation
import StoreKit

/// Whether this iPhone has Anvil Pro, and the way to get it.
///
/// Pro is an auto-renewing subscription bought through the App Store, and the App Store is the only
/// thing that can say whether it is active: `isUnlocked` is read from StoreKit's current
/// entitlements at launch and again whenever a transaction lands, never from a settings file. A
/// self-built copy of the app can't buy Anvil's product, because the product belongs to Anvil's App
/// Store record, not to the code. The development app can preview Pro — see `previewUnlocked` —
/// and, like the developer screen, that switch is compiled out of the public app rather than hidden
/// in it.
///
/// What this can't do is stop someone who compiles the source from changing it. Nothing client-side
/// can. What keeps Pro worth paying for is that the things it ships — Anvil's prompt, its themes,
/// its icons — live in private repositories and are copied into Anvil's own builds, so a build from
/// the open repository gets the machinery and not the goods.
@MainActor
@Observable
final class ProAccess {
  /// The product as set up in App Store Connect: one monthly subscription in the Anvil Pro group.
  static let productID = "com.anvilbase.anvil.pro.monthly"

  /// Whether the App Store says this iPhone has an active subscription.
  private(set) var isEntitled = false
  /// The product, once the App Store has answered. Nil until then, and nil for good on a build the
  /// App Store has no record of — an open-source build, or a sandbox without the product set up.
  private(set) var product: Product?
  private(set) var isPurchasing = false
  /// What went wrong the last time a purchase or restore was tried, for the paywall to show.
  private(set) var lastError: String?

  #if ANVIL_DEV
    /// The development app looking at Pro without buying it. On from launch, because the Pro
    /// screens are what the development app is mostly used to look at; the developer screen's
    /// switch turns it off to see the free app. Not persisted: it is a way of seeing the screens,
    /// not a way of having the feature, and every launch starts with it on again.
    var previewUnlocked = true
  #endif

  var isUnlocked: Bool {
    #if ANVIL_DEV
      return isEntitled || previewUnlocked
    #else
      return isEntitled
    #endif
  }

  /// What a month costs, as the App Store phrases it for this storefront, or nothing until it has
  /// been asked.
  var displayPrice: String? { product?.displayPrice }

  private var updates: Task<Void, Never>?

  init() {
    // Transactions can arrive at any time — a renewal, a purchase finished on another device, a
    // refund — so listen from the start and for as long as the app is up.
    updates = Task { [weak self] in
      for await result in Transaction.updates {
        guard let self else { return }
        if case .verified(let transaction) = result {
          await transaction.finish()
          await self.refreshEntitlement()
        }
      }
    }
    Task { await refresh() }
  }

  func refresh() async {
    await loadProduct()
    await refreshEntitlement()
  }

  private func loadProduct() async {
    // No product is not an error worth showing: it is what an open-source build looks like.
    product = try? await Product.products(for: [Self.productID]).first
  }

  private func refreshEntitlement() async {
    var entitled = false
    for await result in Transaction.currentEntitlements {
      guard case .verified(let transaction) = result else { continue }
      if transaction.productID == Self.productID, transaction.revocationDate == nil {
        entitled = true
      }
    }
    isEntitled = entitled
  }

  func purchase() async {
    guard let product, !isPurchasing else { return }
    isPurchasing = true
    lastError = nil
    defer { isPurchasing = false }
    do {
      switch try await product.purchase() {
      case .success(let verification):
        guard case .verified(let transaction) = verification else {
          lastError = "The App Store's receipt couldn't be verified."
          return
        }
        await transaction.finish()
        await refreshEntitlement()
      case .userCancelled, .pending:
        break
      @unknown default:
        break
      }
    } catch {
      lastError = error.localizedDescription
    }
  }

  /// Asks the App Store again, for a subscription bought on another iPhone or before a reinstall.
  func restore() async {
    lastError = nil
    do {
      try await AppStore.sync()
    } catch {
      lastError = error.localizedDescription
      return
    }
    await refreshEntitlement()
  }
}
