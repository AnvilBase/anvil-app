import CoreGraphics
import CoreML
import Foundation
import StableDiffusion

/// Anvil Dream: a picture from a line of text, made on this iPhone.
///
/// Apple's Core ML build of Stable Diffusion does the heavy lifting — the text encoder, the U-Net
/// and the decoder are its models, loaded from the folder the download unpacked — and the sampling
/// loop is here, because the model is a Latent Consistency Model and needs `LCMScheduler`, which
/// the pipeline Apple ships has no way to take. Four passes of the network, no negative prompt, no
/// guidance: guidance was distilled into the weights before the model was converted, which is
/// what makes four passes enough.
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
        "Anvil Dream is missing \(name). Delete it in Settings › Models and download it again."
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
  /// How long the models stay in memory after a picture.
  private static let idleSeconds: Double = 90

  private struct Pipeline {
    let textEncoder: TextEncoder
    let unet: [ManagedMLModel]
    let decoder: Decoder
    let sampleShape: [Int]
  }

  private var pipeline: Pipeline?
  private var pipelineURL: URL?
  private var release: Task<Void, Never>?

  /// The picture for `prompt`, as the decoded image. Cancelling the task stops between steps.
  func generate(_ prompt: String, from model: ModelFile, seed: UInt64? = nil) async throws
    -> CGImage
  {
    release?.cancel()
    let pipeline = try load(model.url)
    defer { scheduleRelease() }

    let embedding = try pipeline.textEncoder.encode(prompt)
    let hiddenStates = Self.hiddenStates(embedding)
    let scheduler = LCMScheduler(steps: Self.steps)
    let count = pipeline.sampleShape.reduce(1, *)
    var noise = SeededNoise(seed: seed ?? UInt64.random(in: 0...UInt64.max))
    var latent = MLShapedArray<Float32>(scalars: noise.gaussians(count: count), shape: pipeline.sampleShape)

    for timeStep in scheduler.timeSteps {
      try Task.checkCancellation()
      let predicted = try Self.predictNoise(
        pipeline.unet, latent: latent, timeStep: timeStep, hiddenStates: hiddenStates)
      latent = scheduler.step(output: predicted, timeStep: timeStep, sample: latent) {
        noise.gaussians(count: count)
      }
    }
    try Task.checkCancellation()
    guard let image = try pipeline.decoder.decode([latent], scaleFactor: Self.decoderScaleFactor).first
    else { throw Failure.noOutput }
    return image
  }

  func unload() {
    release?.cancel()
    release = nil
    pipeline?.textEncoder.unloadResources()
    pipeline?.unet.forEach { $0.unloadResources() }
    pipeline?.decoder.unloadResources()
    pipeline = nil
    pipelineURL = nil
  }

  // MARK: - Loading

  /// The models in the folder the download unpacked, as Apple's converter lays them out: the
  /// U-Net in two chunks, or in one.
  private func load(_ url: URL) throws -> Pipeline {
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
    let textEncoder = TextEncoder(
      tokenizer: tokenizer, modelAt: try require("TextEncoder.mlmodelc"), configuration: configuration)

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

    let sampleShape = try unet[0].perform { model in
      model.modelDescription.inputDescriptionsByName["sample"]?.multiArrayConstraint?.shape
        .map { $0.intValue }
    } ?? [1, 4, Self.latentSize, Self.latentSize]

    let loaded = Pipeline(textEncoder: textEncoder, unet: unet, decoder: decoder, sampleShape: sampleShape)
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
    _ models: [ManagedMLModel], latent: MLShapedArray<Float32>, timeStep: Int,
    hiddenStates: MLShapedArray<Float32>
  ) throws -> MLShapedArray<Float32> {
    let step = MLShapedArray<Float32>(scalars: [Float(timeStep)], shape: [1])
    let inputs: [String: MLFeatureValue] = [
      "sample": MLFeatureValue(multiArray: MLMultiArray(latent)),
      "timestep": MLFeatureValue(multiArray: MLMultiArray(step)),
      "encoder_hidden_states": MLFeatureValue(multiArray: MLMultiArray(hiddenStates)),
    ]
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

  /// The text encoder answers [1, 77, 768]; the U-Net wants it as [1, 768, 1, 77].
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
}
