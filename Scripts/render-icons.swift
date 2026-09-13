// Renders the app's icon sets: the shipped icon and Anvil Pro's alternates, for both apps.
//
//   swift Scripts/render-icons.swift
//
// Each is the seven-by-seven mark at exactly the size and position of the icon the app shipped
// with — 76-point cells starting at (246, 246) on a 1024 canvas — so switching icons changes the
// colour and nothing else. The public app's primary is the white mark on black and the development
// app's is its inverse; both catalogs get the same alternates.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let rows = ["#######", "#######", "#######", "..###..", "..###..", "#######", "#######"]
let canvas = 1024
let cell = 76
let origin = 246

struct Icon {
  let set: String
  let background: (CGFloat, CGFloat, CGFloat)
  let mark: (CGFloat, CGFloat, CGFloat)
  /// Anvil Pro's icon: the mark as a gold block, the way `GoldAnvil` draws it in the app.
  var gold = false
}

let white: (CGFloat, CGFloat, CGFloat) = (1, 1, 1)
let black: (CGFloat, CGFloat, CGFloat) = (0, 0, 0)
let alternates = [
  Icon(set: "AppIcon-Inverse", background: white, mark: black),
  Icon(set: "AppIcon-Ember", background: black, mark: (1.0, 0.47, 0.16)),
  Icon(set: "AppIcon-Frost", background: black, mark: (0.36, 0.66, 1.0)),
  Icon(set: "AppIcon-Moss", background: black, mark: (0.32, 0.72, 0.46)),
  Icon(set: "AppIcon-Rose", background: black, mark: (1.0, 0.42, 0.62)),
  Icon(set: "AppIcon-Pro", background: black, mark: (0.98, 0.80, 0.30), gold: true),
]

/// The mark's cells as one path, at a vertical offset. Core Graphics counts from the bottom; the
/// rows are written from the top.
func markPath(dy: Int = 0) -> CGPath {
  let path = CGMutablePath()
  for (row, cells) in rows.enumerated() {
    for (column, char) in cells.enumerated() where char == "#" {
      let top = origin + row * cell + dy
      path.addRect(CGRect(x: origin + column * cell, y: canvas - top - cell, width: cell, height: cell))
    }
  }
  return path
}

/// The gold block: the mark stepped down in bronze, and the top face in a gold gradient with a
/// lighter band along its upper edge and a darker one along its lower — the icon-sized version of
/// the bevel the app draws.
func renderGold(in context: CGContext) {
  let space = CGColorSpaceCreateDeviceRGB()
  let depth = Int((Double(cell * 7) * 0.11).rounded())
  // The body. Each layer a little darker than the one above, so the side shades downward.
  for step in stride(from: depth, through: 1, by: -1) {
    let t = CGFloat(step) / CGFloat(depth)
    context.setFillColor(red: 0.62 - 0.22 * t, green: 0.42 - 0.16 * t, blue: 0.10 - 0.05 * t, alpha: 1)
    context.addPath(markPath(dy: step))
    context.fillPath()
  }
  // The face: a diagonal gold gradient clipped to the mark.
  context.saveGState()
  context.addPath(markPath())
  context.clip()
  let gold = CGGradient(
    colorsSpace: space,
    colors: [
      CGColor(red: 1.00, green: 0.94, blue: 0.66, alpha: 1),
      CGColor(red: 0.98, green: 0.80, blue: 0.30, alpha: 1),
      CGColor(red: 0.76, green: 0.53, blue: 0.10, alpha: 1),
      CGColor(red: 0.96, green: 0.79, blue: 0.36, alpha: 1),
    ] as CFArray,
    locations: [0, 0.42, 0.78, 1])!
  let faceTop = CGFloat(canvas - origin)
  let faceBottom = CGFloat(canvas - origin - cell * 7)
  context.drawLinearGradient(
    gold, start: CGPoint(x: CGFloat(origin), y: faceTop),
    end: CGPoint(x: CGFloat(origin + cell * 7), y: faceBottom), options: [])
  // The bevel: light along the top of the face, shade along the bottom, each a soft band.
  let light = CGGradient(
    colorsSpace: space,
    colors: [CGColor(red: 1, green: 1, blue: 1, alpha: 0.55), CGColor(red: 1, green: 1, blue: 1, alpha: 0)] as CFArray,
    locations: [0, 1])!
  context.drawLinearGradient(
    light, start: CGPoint(x: 0, y: faceTop), end: CGPoint(x: 0, y: faceTop - CGFloat(cell) * 0.9), options: [])
  let shade = CGGradient(
    colorsSpace: space,
    colors: [CGColor(red: 0, green: 0, blue: 0, alpha: 0.45), CGColor(red: 0, green: 0, blue: 0, alpha: 0)] as CFArray,
    locations: [0, 1])!
  context.drawLinearGradient(
    shade, start: CGPoint(x: 0, y: faceBottom), end: CGPoint(x: 0, y: faceBottom + CGFloat(cell) * 1.4), options: [])
  context.restoreGState()
}

func render(_ icon: Icon, to url: URL) throws {
  let space = CGColorSpaceCreateDeviceRGB()
  guard
    let context = CGContext(
      data: nil, width: canvas, height: canvas, bitsPerComponent: 8, bytesPerRow: 0, space: space,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
  else { throw NSError(domain: "render-icons", code: 1) }
  context.setFillColor(red: icon.background.0, green: icon.background.1, blue: icon.background.2, alpha: 1)
  context.fill(CGRect(x: 0, y: 0, width: canvas, height: canvas))
  if icon.gold {
    renderGold(in: context)
  } else {
    context.setFillColor(red: icon.mark.0, green: icon.mark.1, blue: icon.mark.2, alpha: 1)
    context.addPath(markPath())
    context.fillPath()
  }
  guard let image = context.makeImage(),
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
  else { throw NSError(domain: "render-icons", code: 2) }
  CGImageDestinationAddImage(destination, image, nil)
  guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "render-icons", code: 3) }
}

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
for app in ["AnvilAI", "AnvilAIDev"] {
  let catalog = root.appendingPathComponent("Apps/\(app)/Assets.xcassets")
  for icon in alternates {
    let set = catalog.appendingPathComponent("\(icon.set).appiconset")
    try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
    try render(icon, to: set.appendingPathComponent("\(icon.set).png"))
    let contents = """
      {
        "images" : [
          {
            "filename" : "\(icon.set).png",
            "idiom" : "universal",
            "platform" : "ios",
            "size" : "1024x1024"
          }
        ],
        "info" : {
          "author" : "xcode",
          "version" : 1
        }
      }

      """
    try contents.write(to: set.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
    print("\(app): \(icon.set)")
  }
}
