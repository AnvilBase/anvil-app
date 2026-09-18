import CoreML
import Foundation

/// The sampler for a Latent Consistency Model: a handful of steps, each one a jump straight to a
/// clean image and back to a noisier one, rather than the fifty small steps a diffusion model
/// takes.
///
/// The same arithmetic as diffusers' `LCMScheduler` with the settings Anvil Dream was trained
/// with — epsilon prediction, the scaled-linear beta schedule, fifty original steps, timestep
/// scaling of ten, no clipping — so a picture from the phone is the picture the reference
/// implementation would make.
struct LCMScheduler {
  /// The training timesteps visited, from the noisiest down.
  let timeSteps: [Int]

  private let alphasCumProd: [Float]
  private static let sigmaData: Float = 0.5
  private static let timestepScaling: Float = 10

  /// - Parameters:
  ///   - steps: How many times the network is run. Four is the usual number for an LCM.
  ///   - trainSteps: Timesteps the model was trained over.
  ///   - originalSteps: The inference schedule the model was distilled from.
  init(steps: Int, trainSteps: Int = 1000, originalSteps: Int = 50) {
    let betaStart: Float = 0.00085
    let betaEnd: Float = 0.012
    var cumulative: [Float] = []
    var product: Float = 1
    for index in 0..<trainSteps {
      // scaled_linear: linear in the square root of beta.
      let root =
        betaStart.squareRoot()
        + (betaEnd.squareRoot() - betaStart.squareRoot()) * Float(index) / Float(trainSteps - 1)
      product *= 1 - root * root
      cumulative.append(product)
    }
    alphasCumProd = cumulative

    // The distillation schedule, noisiest first, then evenly spaced picks from it.
    let stride = trainSteps / originalSteps
    let origin = (1...originalSteps).map { $0 * stride - 1 }.reversed().map { $0 }
    let count = max(1, min(steps, originalSteps))
    timeSteps = (0..<count).map { position in
      origin[Int((Double(position) * Double(originalSteps) / Double(count)).rounded(.down))]
    }
  }

  /// One step: from the network's noise estimate at `timeStep`, the clean image it implies, and
  /// from that the sample for the next timestep — re-noised with `noise` unless this was the last
  /// step, in which case the clean image is the answer.
  func step(
    output: MLShapedArray<Float32>, timeStep: Int, sample: MLShapedArray<Float32>,
    noise: () -> [Float]
  ) -> MLShapedArray<Float32> {
    let alpha = alphasCumProd[timeStep]
    let beta = 1 - alpha
    let scaled = Float(timeStep) * Self.timestepScaling
    let sigmaSquared = Self.sigmaData * Self.sigmaData
    let cSkip = sigmaSquared / (scaled * scaled + sigmaSquared)
    let cOut = scaled / (scaled * scaled + sigmaSquared).squareRoot()

    let samples = sample.scalars
    let outputs = output.scalars
    var denoised = [Float](repeating: 0, count: samples.count)
    let alphaRoot = alpha.squareRoot()
    let betaRoot = beta.squareRoot()
    for index in samples.indices {
      let original = (samples[index] - betaRoot * outputs[index]) / alphaRoot
      denoised[index] = cOut * original + cSkip * samples[index]
    }

    guard let position = timeSteps.firstIndex(of: timeStep), position + 1 < timeSteps.count else {
      return MLShapedArray(scalars: denoised, shape: sample.shape)
    }
    let alphaNext = alphasCumProd[timeSteps[position + 1]]
    let nextRoot = alphaNext.squareRoot()
    let noiseRoot = (1 - alphaNext).squareRoot()
    let fresh = noise()
    for index in denoised.indices {
      denoised[index] = nextRoot * denoised[index] + noiseRoot * fresh[index]
    }
    return MLShapedArray(scalars: denoised, shape: sample.shape)
  }
}

