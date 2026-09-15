import CoreGraphics
import CoreML
import Foundation
import StableDiffusion

/// Anvil Dream: a picture from a line of text, made on this iPhone.
///
/// Apple's Core ML build of Stable Diffusion does the heavy lifting — the text encoders, the U-Net
/// and the decoder are its models, loaded from the folder the download unpacked — and the sampling
/// loop is here, because neither kind of model this runs can be sampled the way the pipeline Apple
/// ships samples.
///
/// Two kinds, told apart by what is in the folder:
/// - Stable Diffusion 1.5 as a Latent Consistency Model, 512 pixels. It needs `LCMScheduler`: four
///   passes, no negative prompt, no guidance, because guidance was distilled into the weights
///   before the model was converted.
/// - SDXL, 1024 pixels, with a second text encoder. The models are few-step ones, each run with
///   `SDXLSampler` the way its package says — the sampler, steps and guidance `SDXLSampling`
///   reads — and guidance its U-Net takes as a batch of two: the empty prompt, then the prompt.
///
/// An actor holding the one loaded pipeline. It stays loaded for a while after a picture so the
/// next one is quick, and lets go on its own after that: the chat model is already the largest
/// thing in memory, and a second model sitting idle beside it is what memory warnings are made of.
actor DreamEngine {
  enum Failure: LocalizedError {
    case incomplete(String)
    case noOutput

    var errorDescription: String? {
      switch self {
      case .incomplete(let name):
        "Anvil Dream is missing \(name). Delete it in Settings › Image and download it again."
      case .noOutput:
        "Anvil Dream produced nothing."
      }
    }
  }

  /// Pictures are 512 by 512: the size the model was trained at, and eight times the latent.
  static let latentSize = 64
  static let steps = 4
  /// Stable Diffusion's latent scaling, which the decoder undoes.
  private static let decoderScaleFactor: Float32 = 0.18215

  /// SDXL's pictures are 1024 by 1024, and it is told so: the size is one of its inputs.
  private static let xlImageSize: Float32 = 1024
  /// SDXL's latent scaling, which differs from 1.5's.
  private static let xlDecoderScaleFactor: Float32 = 0.13025

  /// How long the models stay in memory after a picture.
  private static let idleSeconds: Double = 90

  private struct Pipeline {
    let textEncoder: TextEncoder
    let unet: [ManagedMLModel]
    let decoder: Decoder
    let sampleShape: [Int]
  }

  private struct XLPipeline {
    let textEncoder: TextEncoderXL
    let textEncoder2: TextEncoderXL
    let unet: [ManagedMLModel]
    let decoder: Decoder
    /// The U-Net's batch included: [2, 4, 128, 128] for a model that takes guidance.
    let sampleShape: [Int]
    let timeIdShape: [Int]
    /// How this model is meant to be sampled, as its package says.
    let sampling: SDXLSampling
  }

  private enum Loaded {
    case standard(Pipeline)
    case xl(XLPipeline)
  }

  private var pipeline: Loaded?
  private var pipelineURL: URL?
  /// The empty prompt as an SDXL model's encoders read it: the unconditioned half of guidance, the
  /// same for every picture, so worked out once while the model is loaded.
  private var emptyPromptEncoding: (hiddenStates: MLShapedArray<Float32>, pooled: MLShapedArray<Float32>)?
  private var release: Task<Void, Never>?

  /// The picture for `prompt`, as the decoded image. Cancelling the task stops between passes.
  func generate(_ prompt: String, from model: ModelFile, seed: UInt64? = nil) async throws
    -> CGImage
  {
    release?.cancel()
    let loaded = try load(model.url)
    defer { scheduleRelease() }
    var noise = SeededNoise(seed: seed ?? UInt64.random(in: 0...UInt64.max))
    switch loaded {
    case .standard(let pipeline): return try generate(prompt, with: pipeline, noise: &noise)
    case .xl(let pipeline): return try generate(prompt, with: pipeline, noise: &noise)
    }
  }

  private func generate(
    _ prompt: String, with pipeline: Pipeline, noise: inout SeededNoise
  ) throws -> CGImage {
    let embedding = try pipeline.textEncoder.encode(prompt)
    let hiddenStates = Self.hiddenStates(embedding)
    let scheduler = LCMScheduler(steps: Self.steps)
    let count = pipeline.sampleShape.reduce(1, *)
    var latent = MLShapedArray<Float32>(scalars: noise.gaussians(count: count), shape: pipeline.sampleShape)

    for timeStep in scheduler.timeSteps {
      try Task.checkCancellation()
      let step = MLShapedArray<Float32>(scalars: [Float(timeStep)], shape: [1])
      let predicted = try Self.predictNoise(
        pipeline.unet,
        inputs: [
          "sample": MLFeatureValue(multiArray: MLMultiArray(latent)),
          "timestep": MLFeatureValue(multiArray: MLMultiArray(step)),
          "encoder_hidden_states": MLFeatureValue(multiArray: MLMultiArray(hiddenStates)),
        ])
      latent = scheduler.step(output: predicted, timeStep: timeStep, sample: latent) {
        noise.gaussians(count: count)
      }
    }
    try Task.checkCancellation()
    guard let image = try pipeline.decoder.decode([latent], scaleFactor: Self.decoderScaleFactor).first
    else { throw Failure.noOutput }
    return image
  }

  private func generate(
    _ prompt: String, with xl: XLPipeline, noise: inout SeededNoise
  ) throws -> CGImage {
    let batch = xl.sampleShape[0]
    let guided = batch == 2
    let (prompted, pooled) = try Self.encode(prompt, with: xl)
    // With guidance, the unconditioned half comes first and is the empty prompt as the encoders
    // read it — what the tools these models were made and tuned in sample with — rather than the
    // zeros diffusers substitutes.
    let blank = try guided ? emptyPrompt(for: xl) : nil
    // The encoders are done with for this picture, and the U-Net wants the room.
    xl.textEncoder.unloadResources()
    xl.textEncoder2.unloadResources()
    let hiddenStates = blank.map { Self.batched($0.hiddenStates, prompted) } ?? prompted
    let textEmbeds = blank.map { Self.batched($0.pooled, pooled) } ?? pooled
    let size = Self.xlImageSize
    let timeIds = MLShapedArray<Float32>(
      scalars: (0..<batch).flatMap { _ in [size, size, 0, 0, size, size] }, shape: xl.timeIdShape)

    let latentShape = [1] + xl.sampleShape.dropFirst()
    let count = latentShape.reduce(1, *)
    let sampler = SDXLSampler(method: xl.sampling.method, steps: xl.sampling.steps)
    let guidance = xl.sampling.guidance
    let start = noise.gaussians(count: count).map { $0 * sampler.sigmas[0] }

    let clean = try sampler.sample(start, noise: { noise.gaussians(count: count) }) {
      sample, sigma in
      try Task.checkCancellation()
      let scale = 1 / (sigma * sigma + 1).squareRoot()
      let scaled = sample.map { $0 * scale }
      let input = MLShapedArray<Float32>(
        scalars: guided ? scaled + scaled : scaled, shape: xl.sampleShape)
      let timestep = MLShapedArray<Float32>(
        scalars: [Float](repeating: sampler.timestep(for: sigma), count: batch), shape: [batch])
      let predicted = try Self.predictNoise(
        xl.unet,
        inputs: [
          "sample": MLFeatureValue(multiArray: MLMultiArray(input)),
          "timestep": MLFeatureValue(multiArray: MLMultiArray(timestep)),
          "encoder_hidden_states": MLFeatureValue(multiArray: MLMultiArray(hiddenStates)),
          "text_embeds": MLFeatureValue(multiArray: MLMultiArray(textEmbeds)),
          "time_ids": MLFeatureValue(multiArray: MLMultiArray(timeIds)),
        ]
      ).scalars
      // The noise the model sees, pushed away from the unconditioned guess by the guidance, and
      // from it the clean image: epsilon prediction, in sigma space.
      var denoised = [Float](repeating: 0, count: count)
      for i in 0..<count {
        let epsilon =
          guided
          ? predicted[i] + guidance * (predicted[count + i] - predicted[i])
          : predicted[i]
        denoised[i] = sample[i] - sigma * epsilon
      }
      return denoised
    }

    try Task.checkCancellation()
    let latent = MLShapedArray<Float32>(scalars: clean, shape: latentShape)
    guard let image = try xl.decoder.decode([latent], scaleFactor: Self.xlDecoderScaleFactor).first
    else { throw Failure.noOutput }
    return image
  }

  func unload() {
    release?.cancel()
    release = nil
    switch pipeline {
    case .standard(let loaded):
      loaded.textEncoder.unloadResources()
      loaded.unet.forEach { $0.unloadResources() }
      loaded.decoder.unloadResources()
    case .xl(let loaded):
      loaded.textEncoder.unloadResources()
      loaded.textEncoder2.unloadResources()
      loaded.unet.forEach { $0.unloadResources() }
      loaded.decoder.unloadResources()
    case nil:
      break
    }
    pipeline = nil
    pipelineURL = nil
    emptyPromptEncoding = nil
  }

  // MARK: - Loading

  /// The models in the folder the download unpacked, as Apple's converter lays them out: the
  /// U-Net in two chunks, or in one, and a second text encoder if the model is SDXL.
  private func load(_ url: URL) throws -> Loaded {
    if let pipeline, pipelineURL == url { return pipeline }
    unload()

    let resources = Self.resources(in: url)
    let fileManager = FileManager.default
    func require(_ name: String) throws -> URL {
      let file = resources.appendingPathComponent(name)
      guard fileManager.fileExists(atPath: file.path) else { throw Failure.incomplete(name) }
      return file
    }

    let configuration = MLModelConfiguration()
    // The models were converted for the Neural Engine; Core ML uses the CPU where there isn't one.
    configuration.computeUnits = .cpuAndNeuralEngine

    let tokenizer = try BPETokenizer(
      mergesAt: try require("merges.txt"), vocabularyAt: try require("vocab.json"))

    let chunk1 = resources.appendingPathComponent("UnetChunk1.mlmodelc")
    let chunk2 = resources.appendingPathComponent("UnetChunk2.mlmodelc")
    let unetURLs: [URL]
    if fileManager.fileExists(atPath: chunk1.path), fileManager.fileExists(atPath: chunk2.path) {
      unetURLs = [chunk1, chunk2]
    } else {
      unetURLs = [try require("Unet.mlmodelc")]
    }
    let unet = unetURLs.map { ManagedMLModel(modelAt: $0, configuration: configuration) }
    let decoder = Decoder(modelAt: try require("VAEDecoder.mlmodelc"), configuration: configuration)
    let inputs = try unet[0].perform { $0.modelDescription.inputDescriptionsByName }
    func shape(_ name: String) -> [Int]? {
      inputs[name]?.multiArrayConstraint?.shape.map { $0.intValue }
    }

    let loaded: Loaded
    if fileManager.fileExists(atPath: resources.appendingPathComponent("TextEncoder2.mlmodelc").path) {
      loaded = .xl(
        XLPipeline(
          textEncoder: TextEncoderXL(
            tokenizer: tokenizer, modelAt: try require("TextEncoder.mlmodelc"),
            configuration: configuration),
          textEncoder2: TextEncoderXL(
            tokenizer: tokenizer, modelAt: try require("TextEncoder2.mlmodelc"),
            configuration: configuration),
          unet: unet, decoder: decoder,
          sampleShape: shape("sample") ?? [2, 4, 128, 128],
          timeIdShape: shape("time_ids") ?? [2, 6],
          sampling: SDXLSampling(packageAt: url)))
    } else {
      loaded = .standard(
        Pipeline(
          textEncoder: TextEncoder(
            tokenizer: tokenizer, modelAt: try require("TextEncoder.mlmodelc"),
            configuration: configuration),
          unet: unet, decoder: decoder,
          sampleShape: shape("sample") ?? [1, 4, Self.latentSize, Self.latentSize]))
    }
    pipeline = loaded
    pipelineURL = url
    return loaded
  }

  /// Where the models sit inside an installed image model: the `Resources` folder Apple's
  /// converter bundles, or the folder itself if the archive was made without that level.
  static func resources(in url: URL) -> URL {
    let nested = url.appendingPathComponent("Resources", isDirectory: true)
    return FileManager.default.fileExists(atPath: nested.path) ? nested : url
  }

  private func scheduleRelease() {
    release?.cancel()
    release = Task { [weak self] in
      try? await Task.sleep(for: .seconds(Self.idleSeconds))
      guard !Task.isCancelled else { return }
      await self?.unload()
    }
  }

  // MARK: - The network

  /// One pass of the U-Net, through however many chunks it is in. The chunks are run in turn, each
  /// fed the outputs of the last along with the original inputs, the way Apple's pipeline does it.
  private static func predictNoise(
    _ models: [ManagedMLModel], inputs: [String: MLFeatureValue]
  ) throws -> MLShapedArray<Float32> {
    var features = inputs
    var result: MLFeatureProvider?
    for model in models {
      let provider = try MLDictionaryFeatureProvider(dictionary: features)
      let output = try model.perform { try $0.prediction(from: provider) }
      result = output
      // What the chunk produced, and the original inputs for whatever the next chunk still wants.
      features = inputs
      for name in output.featureNames {
        if let value = output.featureValue(for: name) { features[name] = value }
      }
    }
    guard let result, let name = result.featureNames.first,
      let output = result.featureValue(for: name)?.multiArrayValue
    else { throw Failure.noOutput }
    // The model answers in half precision; the concatenating initializer converts.
    return MLShapedArray<Float32>(MLMultiArray(concatenating: [output], axis: 0, dataType: .float32))
  }

  /// The text encoder answers [1, 77, width]; the U-Net wants it as [1, width, 1, 77].
  private static func hiddenStates(_ embedding: MLShapedArray<Float32>) -> MLShapedArray<Float32> {
    let shape = embedding.shape
    var states = MLShapedArray<Float32>(repeating: 0, shape: [shape[0], shape[2], 1, shape[1]])
    for batch in 0..<shape[0] {
      for token in 0..<shape[1] {
        for channel in 0..<shape[2] {
          states[scalarAt: batch, channel, 0, token] = embedding[scalarAt: batch, token, channel]
        }
      }
    }
    return states
  }

  /// Both encoders' reading of `text`: their words side by side, as the U-Net takes them, and the
  /// pooled sentence from the second.
  private static func encode(
    _ text: String, with xl: XLPipeline
  ) throws -> (hiddenStates: MLShapedArray<Float32>, pooled: MLShapedArray<Float32>) {
    let (words, _) = try xl.textEncoder.encode(text)
    let (words2, pooled) = try xl.textEncoder2.encode(text)
    return (hiddenStates(MLShapedArray(concatenating: [words, words2], alongAxis: 2)), pooled)
  }

  /// A batch of two for guidance: the unconditioned input, then the prompt's.
  private static func batched(
    _ unconditioned: MLShapedArray<Float32>, _ conditioned: MLShapedArray<Float32>
  ) -> MLShapedArray<Float32> {
    MLShapedArray(concatenating: [unconditioned, conditioned], alongAxis: 0)
  }

  /// The empty prompt as `xl`'s encoders read it, worked out the first time it is wanted.
  private func emptyPrompt(
    for xl: XLPipeline
  ) throws -> (hiddenStates: MLShapedArray<Float32>, pooled: MLShapedArray<Float32>) {
    if let emptyPromptEncoding { return emptyPromptEncoding }
    let encoded = try Self.encode("", with: xl)
    emptyPromptEncoding = encoded
    return encoded
  }
}
