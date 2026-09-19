import Foundation
import Observation
import StoreKit

/// Whether this iPhone has Anvil Pro, and the way to get it.
///
/// Pro is an auto-renewing subscription bought through the App Store, by the month or by the year,
/// and the App Store is the only thing that can say whether it is active: `isUnlocked` is read from StoreKit's current
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
  /// The products as set up in App Store Connect: a monthly and a yearly subscription, both in the
  /// Anvil Pro group, so either one is Pro and the App Store handles moving between them.
  static let monthlyID = "com.anvilbase.anvil.pro.monthly"
  static let yearlyID = "com.anvilbase.anvil.pro.yearly"
  static let productIDs = [monthlyID, yearlyID]

  /// Whether the App Store says this iPhone has an active subscription.
  private(set) var isEntitled = false
  /// The products, once the App Store has answered. Nil until then, and nil for good on a build the
  /// App Store has no record of — an open-source build, or a sandbox without the products set up.
  private(set) var monthly: Product?
  private(set) var yearly: Product?
  private(set) var isPurchasing = false
  /// What went wrong the last time a purchase or restore was tried, for the paywall to show.
  private(set) var lastError: String?

  /// The signed transaction the App Store issued for this subscription, exactly as it
  /// arrived. It travels with a request for a Pro model, which anvilai.com will only
  /// serve to someone who has one: Apple signs it, so the site can check it without
  /// asking Apple and without Anvil holding a secret. Nil when Pro isn't active —
  /// including in the development app, where previewing Pro is a local switch and not
  /// a subscription, and so gets nothing to show the server.
  private(set) var subscriptionProof: String?

  #if ANVIL_DEV
    /// The development app looking at Pro without buying it. Off on a fresh install, so the
    /// development app starts out as the free app, which is what the paywall and every locked
    /// feature have to look right in; the developer screen's switch turns it on.
    ///
    /// Remembered across launches now, where it used to reset. Anvil Pro replaces Anvil Core
    /// the moment it starts downloading, so a preview that forgot itself at the next launch
    /// left the phone with a Pro model it wasn't allowed to run and nothing else — a chat that
    /// couldn't load a model, and no way to get one back but downloading Core again. A real
    /// subscription doesn't forget itself between launches; neither should the stand-in.
    ///
    /// A stored property, written through to the defaults, rather than a computed one over
    /// them: this class is observed, and observation sees stored properties change. Computed,
    /// the switch flipped and nothing on screen heard — the Pro page stayed as it was, the model
    /// screen still said to unlock, and the welcome never came — until a screen was rebuilt for
    /// some other reason and read the new value.
    var previewUnlocked: Bool = UserDefaults.standard.bool(forKey: ProAccess.previewKey) {
      didSet { UserDefaults.standard.set(previewUnlocked, forKey: Self.previewKey) }
    }
    private static let previewKey = "proPreviewUnlocked"
  #endif

  var isUnlocked: Bool {
    #if ANVIL_DEV
      return isEntitled || previewUnlocked
    #else
      return isEntitled
    #endif
  }

  /// Whether there is anything to buy: false until the App Store answers, and for good on a build it
  /// has no products for.
  var isAvailable: Bool { monthly != nil || yearly != nil }

  /// How much cheaper a year is than twelve months, as a whole percentage — the number the yearly
  /// button wears. Nil until both prices are known, or if a year isn't actually cheaper.
  var yearlySavingsPercent: Int? {
    guard let monthly, let yearly else { return nil }
    let twelveMonths = monthly.price * 12
    guard twelveMonths > 0, yearly.price < twelveMonths else { return nil }
    let fraction = (twelveMonths - yearly.price) / twelveMonths
    return Int((NSDecimalNumber(decimal: fraction).doubleValue * 100).rounded())
  }

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
    // No products is not an error worth showing: it is what an open-source build looks like.
    let products = (try? await Product.products(for: Self.productIDs)) ?? []
    monthly = products.first { $0.id == Self.monthlyID }
    yearly = products.first { $0.id == Self.yearlyID }
  }

  private func refreshEntitlement() async {
    var entitled = false
    var proof: String?
    for await result in Transaction.currentEntitlements {
      guard case .verified(let transaction) = result else { continue }
      if Self.productIDs.contains(transaction.productID), transaction.revocationDate == nil {
        entitled = true
        // Kept as it came rather than rebuilt from the decoded transaction: the
        // signature is over these bytes, and anything re-encoded is a different
        // string that Apple never signed.
        proof = result.jwsRepresentation
      }
    }
    isEntitled = entitled
    subscriptionProof = proof
  }

  /// Buys one of the two products. Which one is the paywall's choice; both are Pro.
  func purchase(_ product: Product) async {
    guard !isPurchasing else { return }
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
