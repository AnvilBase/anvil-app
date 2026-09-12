import SwiftUI

#if canImport(UIKit)
  import SceneKit
  import UIKit
#endif

/// The mark as an object: one block of ice, cut to the anvil, lit, and turning.
///
/// It is a real model rather than a drawing of one. The outline is extruded into a solid, its edges
/// are worn round so they can catch a light, and it is lit by an environment the way a product shot
/// is — so what you see as it comes round is a shape with a back and two sides, not a stack of
/// copies pretending to have a thickness.
///
/// Nothing to do with it. It turns slowly on its own and takes no touches at all: a finger that
/// lands on it goes to the page underneath, which is what a finger on an empty chat is for.
///
/// Nothing is loaded to make it. The mesh is built from the same seven-by-seven mark ``PixelAnvil``
/// draws, in code, at launch: there is no asset to export, keep in the repository, and remember to
/// re-export the day the mark changes.
struct GlassAnvil: View {
  /// How much room the model is given. The anvil is drawn to about three quarters of it, which
  /// leaves the corners it needs as it turns.
  var size: CGFloat = 168

  @Environment(\.colorScheme) private var scheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    #if canImport(UIKit)
      ZStack {
        // The ground it is standing on, which is the one thing the renderer isn't asked for: a
        // shadow in the scene wants a floor to fall on, and a floor would be a second object on a
        // screen that is meant to have one.
        Ellipse()
          .fill(.black.opacity(scheme == .dark ? 0.5 : 0.26))
          .frame(width: size * 0.6, height: size * 0.1)
          .blur(radius: 14)
          .offset(y: size * 0.34)

        AnvilModel(scheme: scheme, reduceMotion: reduceMotion)
      }
      .frame(width: size, height: size)
      // Nothing here takes a touch. It is the mark, turning; a finger that lands on it belongs to
      // whatever is underneath — the empty chat, which scrolls, and puts the keyboard away.
      .allowsHitTesting(false)
      .accessibilityHidden(true)
    #else
      PixelAnvil(size: size * 0.55)
    #endif
  }
}

#if canImport(UIKit)

  /// The model and its light.
  private struct AnvilModel: UIViewRepresentable {
    let scheme: ColorScheme
    let reduceMotion: Bool

    func makeUIView(context: Context) -> SCNView {
      let view = WatchedSceneView(frame: .zero)
      view.scene = context.coordinator.scene
      view.pointOfView = context.coordinator.camera
      // The page shows through everything the glass doesn't fill, so the model sits on the chat
      // rather than in a window cut into it.
      view.backgroundColor = .clear
      view.isOpaque = false
      view.antialiasingMode = .multisampling4X
      // Not a control and not a target. Everything the model is drawn over goes on receiving the
      // touches that land on it, exactly as though the model were not there.
      view.isUserInteractionEnabled = false
      // Turned on by the coordinator once there is a window to draw into, and off again the
      // moment there isn't — the chat this sits on is the screen people leave open.
      view.rendersContinuously = false
      view.isPlaying = false
      context.coordinator.attach(to: view)
      return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
      context.coordinator.apply(scheme: scheme, reduceMotion: reduceMotion)
    }

    static func dismantleUIView(_ view: SCNView, coordinator: Coordinator) {
      coordinator.stop()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
  }

  /// An `SCNView` that says when it arrives on screen and when it leaves, which is what starts and
  /// stops the turn.
  private final class WatchedSceneView: SCNView {
    var onMoveToWindow: ((Bool) -> Void)?

    override func didMoveToWindow() {
      super.didMoveToWindow()
      onMoveToWindow?(window != nil)
    }
  }

#endif

// MARK: - The mark, as a solid

#if canImport(UIKit)

  extension AnvilModel {

    /// Everything that outlives a redraw: the scene, the model in it, and whatever it is doing.
    final class Coordinator: NSObject {
      let scene = SCNScene()
      let camera = SCNNode()
      /// What gets turned. The two passes hang off it, so they turn as one lump of ice.
      private let anvil = SCNNode()
      /// The far side of the block, seen through the near side, and the near side itself.
      private let farSide = SCNMaterial()
      private let nearSide = SCNMaterial()

      private weak var view: SCNView?

      /// Where the model is pointed, in radians, and the clock turning it.
      private var yaw: Float = -0.34
      private var link: CADisplayLink?
      private var reduceMotion = false

      /// How far it leans back, for good. Just enough to show it has a top.
      private static let pitch: Float = 0.1
      /// How fast it turns: about once every half minute. Slow enough to read as something that
      /// has moved rather than as something that is moving.
      private static let speed: Float = 0.22

      override init() {
        super.init()
        build()
      }

      // MARK: Building it

      private func build() {
        // Twice, because ice is see-through and what you see through it is the back of itself.
        //
        // One pass with the near faces thrown away draws the inside of the far wall; a second pass
        // over the top of it draws the wall nearest you. Drawn in that order they blend the way
        // light actually arrives — in through the front, off the back, out again — and the depth
        // that gives is the whole difference between a block of ice and a shiny cut-out.
        anvil.addChildNode(Self.pass(material: Self.ice(farSide, facing: .front), order: 0))
        anvil.addChildNode(Self.pass(material: Self.ice(nearSide, facing: .back), order: 1))
        anvil.eulerAngles = SCNVector3(Self.pitch, yaw, 0)
        scene.rootNode.addChildNode(anvil)

        camera.camera = {
          let lens = SCNCamera()
          // A short lens, held close. A long one keeps the mark straighter, but it also means
          // every point of a flat face is looking at nearly the same part of the sky — so a face
          // reflects one flat colour, which is what was making this read as painted. Up close the
          // angle changes right across a face, and the hard edges in the sky sweep over it as
          // streaks. The mark can stand the perspective; it could not stand being flat.
          lens.fieldOfView = 30
          lens.zNear = 1
          lens.zFar = 100
          return lens
        }()
        camera.position = SCNVector3(0, 0, 17)
        scene.rootNode.addChildNode(camera)

        // The light it is standing in, as a sky above and a floor below. This is what most of the
        // glass is: an environment to reflect, rather than a lamp to be shone on.
        scene.lightingEnvironment.contents = Self.environment()
        scene.lightingEnvironment.intensity = 3.6

        addLight(.ambient, intensity: 34, at: SCNVector3(0, 0, 0))
        addLight(.omni, intensity: 420, at: SCNVector3(-9, 11, 14))
        // From behind, which is what lights the inside of a frosted edge.
        addLight(.omni, intensity: 260, at: SCNVector3(9, -5, -11))
      }

      private func addLight(_ kind: SCNLight.LightType, intensity: CGFloat, at position: SCNVector3)
      {
        let light = SCNLight()
        light.type = kind
        light.intensity = intensity
        light.castsShadow = false
        let node = SCNNode()
        node.light = light
        node.position = position
        scene.rootNode.addChildNode(node)
      }

      /// The mark's corners in the seven-by-seven grid, walked clockwise from the top left and
      /// measured from the middle, which is where a model wants its origin. Three rows across the
      /// top, a waist three wide, two rows across the base: the same mark ``PixelAnvil`` draws,
      /// read as a boundary.
      private static let corners: [CGPoint] = [
        CGPoint(x: -3.5, y: 3.5), CGPoint(x: 3.5, y: 3.5), CGPoint(x: 3.5, y: 0.5),
        CGPoint(x: 1.5, y: 0.5), CGPoint(x: 1.5, y: -1.5), CGPoint(x: 3.5, y: -1.5),
        CGPoint(x: 3.5, y: -3.5), CGPoint(x: -3.5, y: -3.5), CGPoint(x: -3.5, y: -1.5),
        CGPoint(x: -1.5, y: -1.5), CGPoint(x: -1.5, y: 0.5), CGPoint(x: -3.5, y: 0.5),
      ]

      /// One pass over the block: the mark extruded into a solid, wearing the material it was
      /// given, drawn in its turn.
      private static func pass(material: SCNMaterial, order: Int) -> SCNNode {
        let path = UIBezierPath()
        for (index, corner) in corners.enumerated() {
          if index == 0 { path.move(to: corner) } else { path.addLine(to: corner) }
        }
        path.close()
        path.flatness = 0.01

        let shape = SCNShape(path: path, extrusionDepth: 1.7)
        // The edges are worn round, because ice has no sharp ones. A cut block starts with
        // arrises and loses them within a minute of being out of the mould — and the rounding is
        // also what puts a bright line along every edge, since a curved surface sweeps the whole
        // sky in the width of a millimetre while a flat one shows a single point of it.
        //
        // The corners of the silhouette stay square. Those are the mark, and rounding them would
        // make it a pebble rather than the anvil.
        shape.chamferRadius = 0.3
        shape.chamferMode = .both
        // One material over every part of it — both faces and all the sides — because it is one
        // piece. SceneKit repeats the list to cover them all.
        shape.materials = [material]

        let node = SCNNode(geometry: shape)
        node.renderingOrder = order
        return node
      }

      /// Ice: clear enough to see the back of itself through, cold, and frosted unevenly the way
      /// something frozen is.
      ///
      /// Nothing here is metal. That was what made the last one chrome — a trace of metalness with
      /// the roughness this low is a mirror, and a mirror is the one thing ice is not. What carries
      /// it instead is transparency, a rough patch or two, and an edge that lights up where the
      /// surface turns away.
      private static func ice(_ material: SCNMaterial, facing: SCNCullMode) -> SCNMaterial {
        material.lightingModel = .physicallyBased
        material.metalness.contents = 0.0
        // Frost, as a map rather than a number, so the surface is polished in places and clouded
        // in others. Even roughness is plastic; uneven roughness is frozen.
        material.roughness.contents = frost()
        material.roughness.wrapS = .repeat
        material.roughness.wrapT = .repeat
        material.clearCoat.contents = 1.0
        material.clearCoatRoughness.contents = 0.05
        // Transparency is not a number here, it is worked out per pixel in the shader below — a
        // flat value fogs the whole block evenly, and ice is not evenly anything.
        material.transparency = 1.0
        material.isDoubleSided = false
        material.cullMode = facing
        // Neither pass writes depth. The order they are drawn in is already the order they belong
        // in, and a depth test between two halves of one transparent object only cuts holes in it.
        material.writesToDepthBuffer = false
        material.shaderModifiers = [.fragment: iridescence]
        // Which of the two passes this is, for the shader: the far wall is dimmer, because what
        // you are seeing of it has been through the whole thickness of the block to reach you.
        material.setValue(NSNumber(value: facing == .front ? 1 : 0), forKey: "innerFace")
        return material
      }

      /// The polish: soft blotches, from a coarse grid of random values smoothed up to size. Dark
      /// is glassy, light is clouded, and the whole range is narrow and near the glassy end — cast
      /// ice is clear, and what stops it looking machined is that it is not *evenly* clear.
      private static func frost() -> UIImage {
        let grid = 12
        let size = 96
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        var coarse = [Double](repeating: 0, count: grid * grid)
        for index in coarse.indices {
          seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
          coarse[index] = Double((seed >> 33) & 0xFFFF) / 65535
        }

        var pixels = [UInt8](repeating: 255, count: size * size * 4)
        for row in 0..<size {
          for column in 0..<size {
            let value = smooth(
              coarse, grid: grid, x: Double(column) / Double(size) * Double(grid),
              y: Double(row) / Double(size) * Double(grid))
            let level = UInt8(max(0, min(255, (0.04 + value * 0.2) * 255)))
            let offset = (row * size + column) * 4
            pixels[offset] = level
            pixels[offset + 1] = level
            pixels[offset + 2] = level
          }
        }

        let image = pixels.withUnsafeMutableBytes { bytes -> CGImage? in
          guard
            let context = CGContext(
              data: bytes.baseAddress, width: size, height: size, bitsPerComponent: 8,
              bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
          else { return nil }
          return context.makeImage()
        }
        return image.map(UIImage.init) ?? UIImage()
      }

      /// Reads the coarse grid between its corners, eased across, so the blotches have no straight
      /// edges anywhere in them.
      private static func smooth(_ values: [Double], grid: Int, x: Double, y: Double) -> Double {
        let x0 = Int(x) % grid
        let y0 = Int(y) % grid
        let x1 = (x0 + 1) % grid
        let y1 = (y0 + 1) % grid
        let fx = ease(x - Double(Int(x)))
        let fy = ease(y - Double(Int(y)))
        let top = values[y0 * grid + x0] * (1 - fx) + values[y0 * grid + x1] * fx
        let bottom = values[y1 * grid + x0] * (1 - fx) + values[y1 * grid + x1] * fx
        return top * (1 - fy) + bottom * fy
      }

      private static func ease(_ t: Double) -> Double { t * t * (3 - 2 * t) }

      /// The rainbow, as a few lines of Metal on the end of the fragment shader.
      ///
      /// It has to be worked out from the angle you are looking at the surface from rather than
      /// taken out of the reflection, and the reason is the mark: every face of it is flat, and a
      /// flat face reflects one single point of the sky, so colour coming from the reflection
      /// arrives as one solid colour per face. Painted green, in other words.
      ///
      /// The angle varies across a face even when the reflection doesn't. So the spectrum is hung
      /// on the Fresnel term — nothing where you are looking straight into the glass, everything
      /// where the surface turns away — which puts the colour where a real piece of glass keeps
      /// it: along the edges, and shifting as the thing turns.
      private static let iridescence = """
        #pragma arguments
        float innerFace;
        float onLight;

        #pragma body
        float3 surfaceNormal = normalize(_surface.normal);
        float3 toEye = normalize(_surface.view);
        float facing = saturate(abs(dot(surfaceNormal, toEye)));
        float rim = pow(1.0 - facing, 1.6);

        // Cold. Ice takes the red out of what comes through it — the further light has had to
        // travel inside, the bluer it arrives — so the body cools off as it moves away from the
        // edges, where light has barely been inside it at all.
        float depth = 1.0 - rim;
        _output.color.rgb *= mix(float3(1.0), float3(0.78, 0.93, 1.12), depth * 0.85);

        // The white edge. On a rounded edge this is a line rather than a corner, because the
        // curve sweeps the whole sky across a couple of pixels — which is most of what tells you
        // something is frozen rather than moulded.
        _output.color.rgb += pow(1.0 - facing, 3.0) * mix(1.15, 0.42, onLight);
        float lit = dot(_output.color.rgb, float3(0.299, 0.587, 0.114));

        // How much of it is there at all. Almost none in the middle of a face, where you are
        // looking straight through to whatever is behind — and all of it wherever light is coming
        // off the surface, because a reflection is not something you can see through.
        //
        // Not on a white page, though. Ice this clear over white is white, and an earlier pass of
        // this disappeared onto the paper altogether, so in the light theme it holds much more of
        // itself back and leans on its colour and its shadow instead.
        float clarity = saturate(
          mix(mix(0.16, 0.56, onLight), 1.0, rim) + lit * mix(0.65, 0.35, onLight));
        _output.color *= clarity * mix(1.0, 0.8, innerFace);
        """

      /// The sky it reflects, drawn rather than shipped: bright overhead, a band of window under
      /// that, a horizon, and a dark floor. Nearly colourless, because all the colour comes from
      /// the shader above; what this is for is the two hard edges in it, which travel across a
      /// face as the block turns and read as something with a wet surface.
      private static func environment() -> UIImage {
        let width = 256
        let height = 128
        var pixels = [UInt8](repeating: 0, count: width * height * 4)

        for row in 0..<height {
          let elevation = Double(row) / Double(height - 1)
          let (value, saturation) = sky(at: elevation)
          for column in 0..<width {
            // Hue runs right round the image, so the colour a face reflects depends on which way
            // it is pointing — turn the model and the spectrum travels across it.
            let hue = (Double(column) / Double(width) + elevation * 0.16).truncatingRemainder(
              dividingBy: 1)
            let (red, green, blue) = rgb(hue: hue, saturation: saturation, value: value)
            let offset = (row * width + column) * 4
            pixels[offset] = UInt8(red * 255)
            pixels[offset + 1] = UInt8(green * 255)
            pixels[offset + 2] = UInt8(blue * 255)
            pixels[offset + 3] = 255
          }
        }

        let image = pixels.withUnsafeMutableBytes { bytes -> CGImage? in
          guard
            let context = CGContext(
              data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
              bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
          else { return nil }
          return context.makeImage()
        }
        return image.map(UIImage.init) ?? UIImage()
      }

      /// How bright and how coloured the sky is at a given height: white overhead, a band of
      /// window under it, the spectrum through the middle, a horizon, and a dark floor.
      ///
      /// The band and the horizon are the two edges that matter. A sky that fades smoothly
      /// reflects as a smooth wash and reads as paint; an edge in it reflects as a line that
      /// travels across a face as the model turns, and that is what the eye reads as glass.
      private static func sky(at elevation: Double) -> (value: Double, saturation: Double) {
        switch elevation {
        case ..<0.09: (1, 0.02)
        case ..<0.13: (0.4, 0.1)
        case ..<0.17: (1, 0.03)
        case ..<0.21: (0.88, 0.06)
        case ..<0.5: (0.36, 0.12)
        case ..<0.53: (0.66, 0.05)
        default: (0.14, 0.1)
        }
      }

      /// Hue, saturation and value as red, green and blue. Written out rather than gone through
      /// `UIColor` for, because this is asked thirty-two thousand times to build one small image.
      private static func rgb(hue: Double, saturation: Double, value: Double) -> (
        Double, Double, Double
      ) {
        let sector = hue * 6
        let index = Int(sector) % 6
        let fraction = sector - Double(Int(sector))
        let p = value * (1 - saturation)
        let q = value * (1 - saturation * fraction)
        let t = value * (1 - saturation * (1 - fraction))
        return switch index {
        case 0: (value, t, p)
        case 1: (q, value, p)
        case 2: (p, value, t)
        case 3: (p, q, value)
        case 4: (t, p, value)
        default: (value, p, q)
        }
      }

      // MARK: What the theme changes

      func apply(scheme: ColorScheme, reduceMotion: Bool) {
        self.reduceMotion = reduceMotion
        // Turned on mid-turn it stops where it stands; turned off again it carries on.
        if reduceMotion { stop() } else { start() }
        // Ice is not white, it is very slightly blue, and mostly it is not there at all — so the
        // colour is thin and the transparency does the work. The tint is the only thing the theme
        // changes; the light and the model are the same object in both.
        // Glass has almost no colour of its own — everything you see in a block of cast ice is
        // light that came from somewhere else. So against the dark the body is nearly nothing and
        // the reflections are the whole of it. On a white page it has to be more than that or it
        // vanishes, which is the one place this stops being honest.
        let tint =
          scheme == .dark
          ? UIColor(hue: 0.55, saturation: 0.14, brightness: 0.44, alpha: 1)
          : UIColor(hue: 0.55, saturation: 0.22, brightness: 0.6, alpha: 1)
        let onLight = NSNumber(value: scheme == .dark ? 0 : 1)
        for material in [nearSide, farSide] {
          material.diffuse.contents = tint
          material.setValue(onLight, forKey: "onLight")
        }
      }

      // MARK: Coming and going

      func attach(to view: SCNView) {
        self.view = view
        (view as? WatchedSceneView)?.onMoveToWindow = { [weak self] onScreen in
          guard let self else { return }
          // Off screen there is nothing to draw and no reason to be turning. It picks up from
          // where it left off when it comes back.
          if onScreen { self.start() } else { self.stop() }
        }
      }

      // MARK: Turning

      /// Starts the clock, if there is anything to draw into and any motion allowed at all.
      ///
      /// Stepped a frame at a time rather than handed to an animation. An animation would set the
      /// finished angle at once and leave the turning to the render server, which is fine until
      /// the view comes and goes — and this one does, every time the chat empties and fills.
      private func start() {
        guard !reduceMotion, link == nil, view?.window != nil else { return }
        view?.rendersContinuously = true
        let link = CADisplayLink(target: self, selector: #selector(step))
        // Half rate. Nothing is gained by drawing this sixty times a second at the speed it turns,
        // and it is sitting on the screen people leave open.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 40, preferred: 30)
        link.add(to: .main, forMode: .common)
        self.link = link
      }

      @objc private func step(_ link: CADisplayLink) {
        yaw += Self.speed * Float(link.targetTimestamp - link.timestamp)
        // Wrapped, so a block left turning for a week sits at an angle as exact as one left
        // turning for a minute, rather than at a number too large to be precise about.
        yaw = fmod(yaw, 2 * .pi)
        point()
      }

      /// Stops it where it is and puts the renderer back to sleep.
      func stop() {
        link?.invalidate()
        link = nil
        view?.rendersContinuously = false
      }

      /// Points the model where `yaw` says, with no animation between here and there — every
      /// frame of the turn is one of these.
      private func point() {
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0
        anvil.eulerAngles = SCNVector3(Self.pitch, yaw, 0)
        SCNTransaction.commit()
      }

    }
  }

#endif
