import Foundation

/// The samplers Anvil Dream runs SDXL models with, in sigma space the way k-diffusion runs them: the
/// sample is the clean image plus sigma times noise, and `denoise` is handed the sample and its
/// sigma and answers with the clean image.
///
/// A few-step model is made for one sampler, and its package says which — see `SDXLSampling`.
/// - DPM++ SDE over a Karras schedule: k-diffusion's `sample_dpmpp_sde`, eta one, with the midpoint
///   halfway in log noise. Every step but the last runs the network twice, so five steps are nine
///   passes.
/// - Euler ancestral over a schedule evenly spaced in training time: k-diffusion's
///   `sample_euler_ancestral` with the schedule A1111 calls Automatic. One pass a step.
///
/// Both take the last step to the clean image the network predicts. The noise added between passes
/// is plain Gaussian rather than k-diffusion's Brownian tree, which makes a seed's picture a
/// different picture, not a worse one.
struct SDXLSampler {
  enum Method: Equatable, Sendable {
    case dpmSDEKarras
    case eulerAncestral
  }

  let method: Method
  /// The noise level at each step, noisiest first, ending in zero.
  let sigmas: [Float]
  /// The training schedule's log noise levels, one per timestep, quietest first.
  private let logSigmas: [Float]

  init(method: Method, steps: Int, trainSteps: Int = 1000) {
    self.method = method
    let betaStart: Float = 0.00085
    let betaEnd: Float = 0.012
    var product: Float = 1
    var training: [Float] = []
    for index in 0..<trainSteps {
      // scaled_linear: linear in the square root of beta.
      let root =
        betaStart.squareRoot()
        + (betaEnd.squareRoot() - betaStart.squareRoot()) * Float(index) / Float(trainSteps - 1)
      product *= 1 - root * root
      training.append(((1 - product) / product).squareRoot())
    }
    let logSigmas = training.map { log($0) }
    self.logSigmas = logSigmas

    let count = max(1, steps)
    func ramp(_ index: Int) -> Float { count == 1 ? 0 : Float(index) / Float(count - 1) }
    switch method {
    case .dpmSDEKarras:
      // Karras et al.: evenly spaced in sigma to the power 1/rho, which spends the steps where the
      // picture is decided rather than where it is only noise.
      let rho: Float = 7
      let quietest = pow(training[0], 1 / rho)
      let noisiest = pow(training[trainSteps - 1], 1 / rho)
      sigmas = (0..<count).map { pow(noisiest + ramp($0) * (quietest - noisiest), rho) } + [0]
    case .eulerAncestral:
      // Evenly spaced in training time from the last timestep to the first, each read off the
      // training schedule between whole steps.
      let last = Float(trainSteps - 1)
      sigmas =
        (0..<count).map { index in
          let time = last * (1 - ramp(index))
          let low = Int(time.rounded(.down))
          let high = min(low + 1, trainSteps - 1)
          let weight = time - Float(low)
          return exp((1 - weight) * logSigmas[low] + weight * logSigmas[high])
        } + [0]
    }
  }

  /// The training timestep a noise level corresponds to, between whole steps where it falls
  /// between them: what the U-Net is told the time is.
  func timestep(for sigma: Float) -> Float {
    let logSigma = log(sigma)
    let below = logSigmas.lastIndex { $0 <= logSigma } ?? 0
    let low = min(below, logSigmas.count - 2)
    let high = low + 1
    let weight = min(max((logSigmas[low] - logSigma) / (logSigmas[low] - logSigmas[high]), 0), 1)
    return (1 - weight) * Float(low) + weight * Float(high)
  }

  /// How many times `sample` runs the network: once a step, or twice for every step but the
  /// last when the method takes a midpoint. What a progress bar counts.
  var passCount: Int {
    let steps = max(sigmas.count - 1, 0)
    switch method {
    case .eulerAncestral: return steps
    case .dpmSDEKarras: return max(2 * steps - 1, 0)
    }
  }

  /// The clean image, from `start` — pure noise at `sigmas[0]`. `noise` is asked for fresh
  /// Gaussian noise the size of the sample; `denoise` runs the network.
  func sample(
    _ start: [Float], noise: () -> [Float], denoise: ([Float], Float) throws -> [Float]
  ) throws -> [Float] {
    var sample = start
    for index in 0..<(sigmas.count - 1) {
      let sigma = sigmas[index]
      let next = sigmas[index + 1]
      let denoised = try denoise(sample, sigma)
      guard next > 0 else { return denoised }

      switch method {
      case .eulerAncestral:
        sample = Self.move(sample, toward: denoised, from: sigma, to: next, noise: noise())

      case .dpmSDEKarras:
        // A first-order step to the midpoint, with its share of fresh noise, and the network run
        // again there; then the whole step, taken with what the network saw at the midpoint.
        let midpoint = (sigma * next).squareRoot()
        let halfway = Self.move(sample, toward: denoised, from: sigma, to: midpoint, noise: noise())
        let denoisedHalfway = try denoise(halfway, midpoint)
        sample = Self.move(sample, toward: denoisedHalfway, from: sigma, to: next, noise: noise())
      }
    }
    return sample
  }

  /// One ancestral step from `sigma` to `next`, eta one: the deterministic part taken toward the
  /// clean image, and the rest added back as fresh noise.
  private static func move(
    _ sample: [Float], toward denoised: [Float], from sigma: Float, to next: Float, noise: [Float]
  ) -> [Float] {
    let up = min(next, (next * next * (sigma * sigma - next * next) / (sigma * sigma)).squareRoot())
    let down = (next * next - up * up).squareRoot()
    let ratio = down / sigma
    var moved = [Float](repeating: 0, count: sample.count)
    for i in sample.indices {
      moved[i] = denoised[i] + ratio * (sample[i] - denoised[i]) + up * noise[i]
    }
    return moved
  }
}

/// How an SDXL model is meant to be sampled: the sampler, the steps and the guidance its creator
/// recommends.
///
/// LocalMuse's Core ML conversions write these into the package's `PROVENANCE.json`, under
/// `recommendedInference`. A package that doesn't, or that names a sampler this app doesn't have,
/// is run the way RealVisXL V5 Lightning was checked: DPM++ SDE Karras, five steps, guidance two.
struct SDXLSampling: Equatable, Sendable {
  var method: SDXLSampler.Method
  var steps: Int
  var guidance: Float

  static let fallback = SDXLSampling(method: .dpmSDEKarras, steps: 5, guidance: 2)

  init(method: SDXLSampler.Method, steps: Int, guidance: Float) {
    self.method = method
    self.steps = steps
    self.guidance = guidance
  }

  /// What the package at `url` recommends, or the fallback.
  init(packageAt url: URL) {
    self = .fallback
    let files = [url, DreamEngine.resources(in: url)].map {
      $0.appendingPathComponent("PROVENANCE.json")
    }
    guard
      let data = files.lazy.compactMap({ try? Data(contentsOf: $0) }).first,
      let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let recommended = root["recommendedInference"] as? [String: Any],
      let scheduler = (recommended["scheduler"] as? String)?.lowercased(),
      let steps = (recommended["defaultSteps"] as? NSNumber)?.intValue,
      let guidance = (recommended["defaultCFGScale"] as? NSNumber)?.floatValue
    else { return }

    let method: SDXLSampler.Method
    if scheduler.contains("euler"), scheduler.contains("ancestral") || scheduler.hasSuffix(" a") {
      method = .eulerAncestral
    } else if scheduler.contains("sde"), !scheduler.contains("2m") {
      method = .dpmSDEKarras
    } else {
      return
    }
    self.init(
      method: method, steps: min(max(steps, 1), 50), guidance: min(max(guidance, 1), 20))
  }
}

/// Gaussian noise from a seed, so the same seed and prompt make the same picture. SplitMix64
/// under a Box–Muller transform: small, and the same on every phone.
struct SeededNoise {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  private mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }

  /// A number in (0, 1]: never zero, so its logarithm is always finite.
  private mutating func uniform() -> Double {
    (Double(next() >> 11) + 1) / Double(1 << 53)
  }

  mutating func gaussians(count: Int) -> [Float] {
    var values = [Float](repeating: 0, count: count)
    var index = 0
    while index < count {
      let radius = (-2 * log(uniform())).squareRoot()
      let angle = 2 * Double.pi * uniform()
      values[index] = Float(radius * cos(angle))
      index += 1
      if index < count {
        values[index] = Float(radius * sin(angle))
        index += 1
      }
    }
    return values
  }
}
