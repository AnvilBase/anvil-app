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
}

let white: (CGFloat, CGFloat, CGFloat) = (1, 1, 1)
let black: (CGFloat, CGFloat, CGFloat) = (0, 0, 0)
let alternates = [
  Icon(set: "AppIcon-Inverse", background: white, mark: black),
  Icon(set: "AppIcon-Ember", background: black, mark: (1.0, 0.47, 0.16)),
  Icon(set: "AppIcon-Frost", background: black, mark: (0.36, 0.66, 1.0)),
  Icon(set: "AppIcon-Moss", background: black, mark: (0.32, 0.72, 0.46)),
  Icon(set: "AppIcon-Rose", background: black, mark: (1.0, 0.42, 0.62)),
]

func render(_ icon: Icon, to url: URL) throws {
  let space = CGColorSpaceCreateDeviceRGB()
  guard
    let context = CGContext(
      data: nil, width: canvas, height: canvas, bitsPerComponent: 8, bytesPerRow: 0, space: space,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
  else { throw NSError(domain: "render-icons", code: 1) }
  context.setFillColor(red: icon.background.0, green: icon.background.1, blue: icon.background.2, alpha: 1)
  context.fill(CGRect(x: 0, y: 0, width: canvas, height: canvas))
  context.setFillColor(red: icon.mark.0, green: icon.mark.1, blue: icon.mark.2, alpha: 1)
  for (row, cells) in rows.enumerated() {
    for (column, char) in cells.enumerated() where char == "#" {
      // Core Graphics counts from the bottom; the rows are written from the top.
      let top = origin + row * cell
      context.fill(CGRect(x: origin + column * cell, y: canvas - top - cell, width: cell, height: cell))
    }
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
