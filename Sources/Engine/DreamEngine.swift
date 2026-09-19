import CoreGraphics
import CoreML
import Foundation
import StableDiffusion
import os

/// Anvil Dream: a picture from a line of text, made on this iPhone.
///
/// Apple's Core ML build of Stable Diffusion does the heavy lifting — the text encoders, the U-Net
/// and the decoder are its models, loaded from the folder the download unpacked — and the sampling
/// loop is here, because neither kind of model this runs can be sampled the way the pipeline Apple
/// ships samples.
///
/// Two kinds, told apart by what is in the folder:
/// - Anvil Dream Lite: Stable Diffusion 1.5 as a Latent Consistency Model, 512 pixels, one text
///   encoder. It needs `LCMScheduler`: four passes, no negative prompt, no guidance, because
///   guidance was distilled into the weights before the model was converted.
/// - Anvil Dream: SDXL, 1024 pixels, with a second text encoder. A few-step model, run with
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
        // again on its own, or Settings › Image offers the model again.
        "The image model didn't arrive in one piece — \(name) is missing. Anvil has removed it; "
          + "Settings › Image has it again."
      case .noOutput:
        "The image model produced nothing."
      case .notEnoughMemory:
        "Not enough memory for a picture right now. Try again from a new chat, or after closing "
          + "other apps."
      }
    }
  }

  /// Anvil Dream Lite's pictures are 512 by 512: the size the model was trained at, and eight
  /// times the latent.
  private static let liteLatentSize = 64
  private static let liteSteps = 4
  /// Stable Diffusion 1.5's latent scaling, which the decoder undoes.
  private static let liteDecoderScaleFactor: Float32 = 0.18215
  /// SDXL's pictures are 1024 by 1024, and it is told so: the size is one of its inputs.
  private static let xlImageSize: Float32 = 1024
  /// SDXL's latent scaling, which differs from 1.5's.
  private static let xlDecoderScaleFactor: Float32 = 0.13025
  /// How long the models stay in memory after a picture.
  private static let idleSeconds: Double = 90
  /// What a pipeline needs free before it is loaded: SDXL's weights are 3.1 GB and it works in
  /// more than that; the Lite model's are under a gigabyte. A first estimate from one crash, not
  /// a measurement, and worth revising once there is one: too high refuses pictures that would
  /// have worked, too low is the app killed. Refusing is the one of the two anyone can recover
  /// from.
  private static let xlMemoryNeeded: Int = 3_500_000_000
  private static let liteMemoryNeeded: Int = 1_500_000_000
  /// Below this after a picture, the models are let go at once rather than kept for the next
  /// one: the room they hold is room the chat is about to need.
  private static let memoryComfortable: Int = 1_500_000_000

  /// Anvil Dream Lite: one text encoder, the U-Net, the decoder.
  private struct LitePipeline {
    let textEncoder: TextEncoder
    let unet: [ManagedMLModel]
    let decoder: Decoder
    let sampleShape: [Int]
  }

  /// Anvil Dream: two text encoders, the U-Net, the decoder, and how its package says to sample.
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
    case lite(LitePipeline)
    case xl(XLPipeline)
  }

  private var pipeline: Loaded?
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
    let freshlyLoaded = pipeline == nil || pipelineURL != model.url
    if freshlyLoaded {
      let needed = Self.isXL(model.url) ? Self.xlMemoryNeeded : Self.liteMemoryNeeded
      if os_proc_available_memory() < needed { throw Failure.notEnoughMemory }
      progress(.loading)
    }
    let loaded = try load(model.url)
    progress(.reading)
    defer {
      if os_proc_available_memory() < Self.memoryComfortable { unload() } else { scheduleRelease() }
    }
    var noise = SeededNoise(seed: seed ?? UInt64.random(in: 0...UInt64.max))
    switch loaded {
    case .lite(let pipeline):
      return try generate(prompt, with: pipeline, noise: &noise, freshlyLoaded: freshlyLoaded, progress: progress)
    case .xl(let pipeline):
      return try generate(prompt, with: pipeline, noise: &noise, freshlyLoaded: freshlyLoaded, progress: progress)
    }
  }

  /// Anvil Dream Lite's loop: the Latent Consistency sampler, four passes, no guidance.
  private func generate(
    _ prompt: String, with pipeline: LitePipeline, noise: inout SeededNoise,
    freshlyLoaded: Bool, progress: @Sendable (PictureStage) -> Void
  ) throws -> CGImage {
    let embedding = try pipeline.textEncoder.encode(prompt)
    let hiddenStates = Self.hiddenStates(embedding)
    pipeline.textEncoder.unloadResources()
    let scheduler = LCMScheduler(steps: Self.liteSteps)
    let count = pipeline.sampleShape.reduce(1, *)
    var latent = MLShapedArray<Float32>(scalars: noise.gaussians(count: count), shape: pipeline.sampleShape)
    let passes = scheduler.timeSteps.count

    for (index, timeStep) in scheduler.timeSteps.enumerated() {
      try Task.checkCancellation()
      let pass = index + 1
      progress(pass == 1 && freshlyLoaded ? .preparing : .painting(pass: pass, of: passes))
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
    progress(.finishing)
    guard let image = try pipeline.decoder.decode([latent], scaleFactor: Self.liteDecoderScaleFactor).first
    else { throw Failure.noOutput }
    return image
  }

  /// Anvil Dream's loop: the sampler its package names, with guidance however its U-Net takes it.
  private func generate(
    _ prompt: String, with pipeline: XLPipeline, noise: inout SeededNoise,
    freshlyLoaded: Bool, progress: @Sendable (PictureStage) -> Void
  ) throws -> CGImage {
    let batch = pipeline.sampleShape[0]
    let guidance = pipeline.sampling.guidance
    // Guidance is worth doing whenever the package asks for it, and how it is done follows from
    // the U-Net's own batch. One built for two rows takes both halves in a single call. One built
    // for a single row takes the same two halves as two calls, which is the same arithmetic while
    // only ever holding one batch — half the peak, on a phone that was being killed for it.
    let guided = guidance > 1
    let stacked = guided && batch == 2
    let sequential = guided && batch == 1
    let (prompted, pooled) = try Self.encode(prompt, with: pipeline)
    // With guidance, the unconditioned half is the empty prompt as the encoders read it — what the
    // tools these models were made and tuned in sample with — rather than the zeros diffusers
    // substitutes.
    let blank = try guided ? emptyPrompt(for: pipeline) : nil
    // The encoders are done with for this picture, and the U-Net wants the room.
    pipeline.textEncoder.unloadResources()
    pipeline.textEncoder2.unloadResources()
    let hiddenStates: MLShapedArray<Float32>
    let textEmbeds: MLShapedArray<Float32>
    if stacked, let blank {
      hiddenStates = Self.batched(blank.hiddenStates, prompted)
      textEmbeds = Self.batched(blank.pooled, pooled)
    } else {
      hiddenStates = prompted
      textEmbeds = pooled
    }
    let size = Self.xlImageSize
    let timeIds = MLShapedArray<Float32>(
      scalars: (0..<batch).flatMap { _ in [size, size, 0, 0, size, size] }, shape: pipeline.timeIdShape)

    let latentShape = [1] + pipeline.sampleShape.dropFirst()
    let count = latentShape.reduce(1, *)
    let sampler = SDXLSampler(method: pipeline.sampling.method, steps: pipeline.sampling.steps)
    let start = noise.gaussians(count: count).map { $0 * sampler.sigmas[0] }
    let passes = sampler.passCount
    var pass = 0

    let clean = try sampler.sample(start, noise: { noise.gaussians(count: count) }) {
      sample, sigma in
      try Task.checkCancellation()
      pass += 1
      // The first pass of a freshly loaded U-Net is where Core ML compiles it for the Neural
      // Engine — minutes, the first time on a phone — and "Step 1 of 7" over that read as
      // stuck. Said as what it is; the steps count from the second pass.
      progress(pass == 1 && freshlyLoaded ? .preparing : .painting(pass: pass, of: passes))
      let scale = 1 / (sigma * sigma + 1).squareRoot()
      let scaled = sample.map { $0 * scale }
      let input = MLShapedArray<Float32>(
        scalars: stacked ? scaled + scaled : scaled, shape: pipeline.sampleShape)
      let timestep = MLShapedArray<Float32>(
        scalars: [Float](repeating: sampler.timestep(for: sigma), count: batch), shape: [batch])
      func predict(
        _ states: MLShapedArray<Float32>, _ embeds: MLShapedArray<Float32>
      ) throws -> [Float] {
        try Self.predictNoise(
          pipeline.unet,
          inputs: [
            "sample": MLFeatureValue(multiArray: MLMultiArray(input)),
            "timestep": MLFeatureValue(multiArray: MLMultiArray(timestep)),
            "encoder_hidden_states": MLFeatureValue(multiArray: MLMultiArray(states)),
            "text_embeds": MLFeatureValue(multiArray: MLMultiArray(embeds)),
            "time_ids": MLFeatureValue(multiArray: MLMultiArray(timeIds)),
          ]
        ).scalars
      }

      // The noise the model sees, pushed away from the unconditioned guess by the guidance, and
      // from it the clean image: epsilon prediction, in sigma space.
      var denoised = [Float](repeating: 0, count: count)
      if sequential, let blank {
        let unconditioned = try predict(blank.hiddenStates, blank.pooled)
        try Task.checkCancellation()
        let conditioned = try predict(hiddenStates, textEmbeds)
        for i in 0..<count {
          let epsilon = unconditioned[i] + guidance * (conditioned[i] - unconditioned[i])
          denoised[i] = sample[i] - sigma * epsilon
        }
      } else {
        let predicted = try predict(hiddenStates, textEmbeds)
        for i in 0..<count {
          let epsilon =
            stacked
            ? predicted[i] + guidance * (predicted[count + i] - predicted[i])
            : predicted[i]
          denoised[i] = sample[i] - sigma * epsilon
        }
      }
      return denoised
    }

    try Task.checkCancellation()
    progress(.finishing)
    let latent = MLShapedArray<Float32>(scalars: clean, shape: latentShape)
    guard let image = try pipeline.decoder.decode([latent], scaleFactor: Self.xlDecoderScaleFactor).first
    else { throw Failure.noOutput }
    return image
  }

  func unload() {
    release?.cancel()
    release = nil
    switch pipeline {
    case .lite(let loaded):
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

  /// Whether the folder holds the SDXL model: a second text encoder says so.
  private static func isXL(_ url: URL) -> Bool {
    FileManager.default.fileExists(
      atPath: resources(in: url).appendingPathComponent("TextEncoder2.mlmodelc").path)
  }

  /// The models in the folder the download unpacked, as Apple's converter lays them out: the
  /// U-Net in two chunks or in one, the decoder, and a text encoder — two of them for SDXL.
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

    let loaded: Loaded
    let secondEncoder = resources.appendingPathComponent("TextEncoder2.mlmodelc")
    if fileManager.fileExists(atPath: secondEncoder.path) {
      loaded = .xl(
        XLPipeline(
          textEncoder: TextEncoderXL(
            tokenizer: tokenizer, modelAt: try require("TextEncoder.mlmodelc"),
            configuration: configuration),
          textEncoder2: TextEncoderXL(
            tokenizer: tokenizer, modelAt: secondEncoder, configuration: configuration),
          unet: unet, decoder: decoder,
          sampleShape: shape("sample") ?? [2, 4, 128, 128],
          timeIdShape: shape("time_ids") ?? [2, 6],
          sampling: SDXLSampling(packageAt: url)))
    } else {
      loaded = .lite(
        LitePipeline(
          textEncoder: TextEncoder(
            tokenizer: tokenizer, modelAt: try require("TextEncoder.mlmodelc"),
            configuration: configuration),
          unet: unet, decoder: decoder,
          sampleShape: shape("sample") ?? [1, 4, Self.liteLatentSize, Self.liteLatentSize]))
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

  /// Both encoders' reading of `text`: their words side by side, as the U-Net takes them, and the
  /// pooled sentence from the second.
  private static func encode(
    _ text: String, with pipeline: XLPipeline
  ) throws -> (hiddenStates: MLShapedArray<Float32>, pooled: MLShapedArray<Float32>) {
    let (words, _) = try pipeline.textEncoder.encode(text)
    let (words2, pooled) = try pipeline.textEncoder2.encode(text)
    return (hiddenStates(MLShapedArray(concatenating: [words, words2], alongAxis: 2)), pooled)
  }

  /// A text encoder answers [1, 77, width]; the U-Net wants it as [1, width, 1, 77].
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
    for pipeline: XLPipeline
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
  /// The U-Net's first pass after a load: Core ML compiling it for this phone, the first time.
  case preparing
  case painting(pass: Int, of: Int)
  case finishing

  var fraction: Double {
    switch self {
    case .loading: 0.02
    case .reading: 0.08
    case .preparing: 0.1
    case .painting(let pass, let passes):
      passes > 0 ? 0.1 + 0.8 * Double(max(pass - 1, 0)) / Double(passes) : 0.1
    case .finishing: 0.92
    }
  }

  /// The line for the screen, naming the model where the model is what is happening: "Loading
  /// Anvil Dream Lite…", "Preparing Anvil Dream for this iPhone…".
  func label(modelName: String) -> String {
    switch self {
    case .loading: "Loading \(modelName)"
    case .reading: "Reading the prompt"
    case .preparing: "Preparing \(modelName) for this iPhone"
    case .painting(let pass, let passes): "Step \(pass) of \(passes)"
    case .finishing: "Finishing"
    }
  }
}
