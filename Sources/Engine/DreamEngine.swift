import CoreGraphics
import CoreML
import Foundation
import StableDiffusion
import os

/// Anvil Dream: a picture from a line of text, made on this iPhone.
///
/// Apple's Core ML build of Stable Diffusion does the heavy lifting — the two text encoders, the
/// U-Net and the decoder are its models, loaded from the folder the download unpacked — and the
/// sampling loop is here, because the model is a few-step SDXL one, made for a sampler the pipeline
/// Apple ships doesn't have. `SDXLSampler` runs it the way its package says — the sampler, steps
/// and guidance `SDXLSampling` reads — at 1024 pixels, with guidance the U-Net takes as a batch of
/// two: the empty prompt, then the prompt.
///
/// An actor holding the one loaded pipeline. It stays loaded for a while after a picture so the
/// next one is quick, and lets go on its own after that: the chat model is already the largest
/// thing in memory, and a second model sitting idle beside it is what memory warnings are made of.
actor DreamEngine {
  enum Failure: LocalizedError {
    case incomplete(String)
    /// The first Anvil Dream, a Stable Diffusion 1.5 model, which this engine no longer runs.
    case outdated
    case noOutput
    /// The phone hasn't the memory left for the picture model beside what is already loaded.
    /// Said rather than tried: a picture attempted without the room is the app killed mid-way,
    /// which is what happened — 6.3 GB resident, the chat model and this one together, on a
    /// phone with 8.
    case notEnoughMemory

    var errorDescription: String? {
      switch self {
      case .incomplete(let name):
        // No instruction to delete anything. A folder missing a file the model can't run without is
        // thrown away by the app itself the moment this is raised — see `ChatModel.repairImageModel`
        // — and either the download it came from is still on the phone, in which case it is unpacked
        // again on its own, or Settings › Models offers Anvil Dream again.
        "The image generation model didn't arrive in one piece — \(name) is missing. Anvil has "
          + "removed it; Settings › Models has it again."
      case .outdated:
        "This is the old image generation model. Update it in Settings › Models to make pictures."
      case .noOutput:
        "The image generation model produced nothing."
      case .notEnoughMemory:
        "Not enough memory for a picture right now. Try again from a new chat, or after closing "
          + "other apps."
      }
    }
  }

  /// Pictures are 1024 by 1024, and the model is told so: the size is one of its inputs.
  private static let imageSize: Float32 = 1024
  /// SDXL's latent scaling, which the decoder undoes.
  private static let decoderScaleFactor: Float32 = 0.13025
  /// How long the models stay in memory after a picture.
  private static let idleSeconds: Double = 90
  /// What the pipeline needs free before it is loaded: its weights are 3.1 GB and it works in
  /// more than that. A first estimate from one crash, not a measurement, and worth revising
  /// once there is one: too high refuses pictures that would have worked, too low is the app
  /// killed. Refusing is the one of the two anyone can recover from.
  private static let memoryNeeded: Int = 3_500_000_000
  /// Below this after a picture, the models are let go at once rather than kept for the next
  /// one: the room they hold is room the chat is about to need.
  private static let memoryComfortable: Int = 1_500_000_000

  private struct Pipeline {
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

  private var pipeline: Pipeline?
  private var pipelineURL: URL?
  /// The empty prompt as the encoders read it: the unconditioned half of guidance, the same for
  /// every picture, so worked out once while the model is loaded.
  private var emptyPromptEncoding: (hiddenStates: MLShapedArray<Float32>, pooled: MLShapedArray<Float32>)?
  private var release: Task<Void, Never>?

  /// The picture for `prompt`, as the decoded image. Cancelling the task stops between passes.
  /// Makes the picture, telling `progress` where it has got to as it goes: the stages are what
  /// the screen shows under "Making the picture…", so a minute's wait has a number in it.
  func generate(
    _ prompt: String, from model: ModelFile, seed: UInt64? = nil,
    progress: @Sendable (PictureStage) -> Void = { _ in }
  ) async throws -> CGImage {
    release?.cancel()
    // Asked before anything is loaded, of the budget iOS actually gives this process — not
    // the phone's RAM, which the chat model has already taken most of. A picture there is no
    // room for is refused in a sentence rather than attempted and killed.
    if pipeline == nil, os_proc_available_memory() < Self.memoryNeeded {
      throw Failure.notEnoughMemory
    }
    if pipeline == nil || pipelineURL != model.url { progress(.loading) }
    let pipeline = try load(model.url)
    progress(.reading)
    defer {
      if os_proc_available_memory() < Self.memoryComfortable { unload() } else { scheduleRelease() }
    }
    var noise = SeededNoise(seed: seed ?? UInt64.random(in: 0...UInt64.max))

    let batch = pipeline.sampleShape[0]
    let guided = batch == 2
    let (prompted, pooled) = try Self.encode(prompt, with: pipeline)
    // With guidance, the unconditioned half comes first and is the empty prompt as the encoders
    // read it — what the tools these models were made and tuned in sample with — rather than the
    // zeros diffusers substitutes.
    let blank = try guided ? emptyPrompt(for: pipeline) : nil
    // The encoders are done with for this picture, and the U-Net wants the room.
    pipeline.textEncoder.unloadResources()
    pipeline.textEncoder2.unloadResources()
    let hiddenStates = blank.map { Self.batched($0.hiddenStates, prompted) } ?? prompted
    let textEmbeds = blank.map { Self.batched($0.pooled, pooled) } ?? pooled
    let size = Self.imageSize
    let timeIds = MLShapedArray<Float32>(
      scalars: (0..<batch).flatMap { _ in [size, size, 0, 0, size, size] }, shape: pipeline.timeIdShape)

    let latentShape = [1] + pipeline.sampleShape.dropFirst()
    let count = latentShape.reduce(1, *)
    let sampler = SDXLSampler(method: pipeline.sampling.method, steps: pipeline.sampling.steps)
    let guidance = pipeline.sampling.guidance
    let start = noise.gaussians(count: count).map { $0 * sampler.sigmas[0] }
    let passes = sampler.passCount
    var pass = 0

    let clean = try sampler.sample(start, noise: { noise.gaussians(count: count) }) {
      sample, sigma in
      try Task.checkCancellation()
      pass += 1
      progress(.painting(pass: pass, of: passes))
      let scale = 1 / (sigma * sigma + 1).squareRoot()
      let scaled = sample.map { $0 * scale }
      let input = MLShapedArray<Float32>(
        scalars: guided ? scaled + scaled : scaled, shape: pipeline.sampleShape)
      let timestep = MLShapedArray<Float32>(
        scalars: [Float](repeating: sampler.timestep(for: sigma), count: batch), shape: [batch])
      let predicted = try Self.predictNoise(
        pipeline.unet,
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
    progress(.finishing)
    let latent = MLShapedArray<Float32>(scalars: clean, shape: latentShape)
    guard let image = try pipeline.decoder.decode([latent], scaleFactor: Self.decoderScaleFactor).first
    else { throw Failure.noOutput }
    return image
  }

  func unload() {
    release?.cancel()
    release = nil
    pipeline?.textEncoder.unloadResources()
    pipeline?.textEncoder2.unloadResources()
    pipeline?.unet.forEach { $0.unloadResources() }
    pipeline?.decoder.unloadResources()
    pipeline = nil
    pipelineURL = nil
    emptyPromptEncoding = nil
  }

  // MARK: - Loading

  /// The models in the folder the download unpacked, as Apple's converter lays them out: two text
  /// encoders, the U-Net in two chunks or in one, and the decoder.
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
    // The first Anvil Dream had one text encoder. A phone that hasn't updated it still has that
    // folder, and is told to update rather than that a file is missing.
    let secondEncoder = resources.appendingPathComponent("TextEncoder2.mlmodelc")
    guard fileManager.fileExists(atPath: secondEncoder.path) else {
      throw fileManager.fileExists(atPath: resources.appendingPathComponent("TextEncoder.mlmodelc").path)
        ? Failure.outdated : Failure.incomplete("TextEncoder2.mlmodelc")
    }

    let configuration = MLModelConfiguration()
    // The models were converted for the Neural Engine; Core ML uses the CPU where there isn't one.
    configuration.computeUnits = .cpuAndNeuralEngine

    // Read the vocabulary here first, with a `try` that can fail. Apple's tokenizer reads it
    // with a `try!` that can't: a vocab.json that doesn't parse — empty, from an unpack that
    // stopped short — took the whole app down at the moment someone asked for a picture. A
    // file that fails here is reported as what it is, and the library throws the folder away.
    let vocabularyURL = try require("vocab.json")
    guard let vocabulary = try? Data(contentsOf: vocabularyURL),
      (try? JSONDecoder().decode([String: Int].self, from: vocabulary)) != nil
    else { throw Failure.incomplete("vocab.json") }
    let tokenizer = try BPETokenizer(mergesAt: try require("merges.txt"), vocabularyAt: vocabularyURL)

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

    let loaded = Pipeline(
      textEncoder: TextEncoderXL(
        tokenizer: tokenizer, modelAt: try require("TextEncoder.mlmodelc"),
        configuration: configuration),
      textEncoder2: TextEncoderXL(
        tokenizer: tokenizer, modelAt: secondEncoder, configuration: configuration),
      unet: unet, decoder: decoder,
      sampleShape: shape("sample") ?? [2, 4, 128, 128],
      timeIdShape: shape("time_ids") ?? [2, 6],
      sampling: SDXLSampling(packageAt: url))
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

  /// Both encoders' reading of `text`: their words side by side, as the U-Net takes them, and the
  /// pooled sentence from the second.
  private static func encode(
    _ text: String, with pipeline: Pipeline
  ) throws -> (hiddenStates: MLShapedArray<Float32>, pooled: MLShapedArray<Float32>) {
    let (words, _) = try pipeline.textEncoder.encode(text)
    let (words2, pooled) = try pipeline.textEncoder2.encode(text)
    return (hiddenStates(MLShapedArray(concatenating: [words, words2], alongAxis: 2)), pooled)
  }

  /// The text encoders answer [1, 77, width]; the U-Net wants it as [1, width, 1, 77].
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

  /// A batch of two for guidance: the unconditioned input, then the prompt's.
  private static func batched(
    _ unconditioned: MLShapedArray<Float32>, _ conditioned: MLShapedArray<Float32>
  ) -> MLShapedArray<Float32> {
    MLShapedArray(concatenating: [unconditioned, conditioned], alongAxis: 0)
  }

  /// The empty prompt as `pipeline`'s encoders read it, worked out the first time it is wanted.
  private func emptyPrompt(
    for pipeline: Pipeline
  ) throws -> (hiddenStates: MLShapedArray<Float32>, pooled: MLShapedArray<Float32>) {
    if let emptyPromptEncoding { return emptyPromptEncoding }
    let encoded = try Self.encode("", with: pipeline)
    emptyPromptEncoding = encoded
    return encoded
  }
}

/// Where a picture has got to, for the screen to say. The stages are the ones anyone waiting
/// would want named: the model coming off disk (the long one, the first time), the prompt being
/// read, the passes of painting counted out, and the decode at the end. `fraction` lays them
/// along one bar: loading and reading take the first tenth between them, the painting the next
/// eight, the finish the last.
enum PictureStage: Equatable, Sendable {
  case loading
  case reading
  case painting(pass: Int, of: Int)
  case finishing

  var fraction: Double {
    switch self {
    case .loading: 0.02
    case .reading: 0.08
    case .painting(let pass, let passes):
      passes > 0 ? 0.1 + 0.8 * Double(max(pass - 1, 0)) / Double(passes) : 0.1
    case .finishing: 0.92
    }
  }

  var label: String {
    switch self {
    case .loading: "Loading the model…"
    case .reading: "Reading the prompt…"
    case .painting(let pass, let passes): "Step \(pass) of \(passes)…"
    case .finishing: "Finishing…"
    }
  }
}
