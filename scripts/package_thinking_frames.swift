import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Losslessly split the generated 2x2 action sheet; do not redraw or alter the character.
let source = "design/brand/animation/thinking-sheet-v1.png"
let input = CGImageSourceCreateWithURL(URL(fileURLWithPath: source) as CFURL, nil)!
let sheet = CGImageSourceCreateImageAtIndex(input, 0, nil)!
precondition(sheet.width == sheet.height && sheet.width % 2 == 0)
let side = sheet.width / 2
for index in 0..<4 {
    let crop = sheet.cropping(to: CGRect(x: (index % 2) * side, y: (index / 2) * side, width: side, height: side))!
    let name = "CodePaxThinking\(index)"
    let directory = URL(fileURLWithPath: "CodePax/Assets.xcassets/\(name).imageset")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let destination = CGImageDestinationCreateWithURL(directory.appendingPathComponent("\(name).png") as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, crop, nil)
    precondition(CGImageDestinationFinalize(destination))
    let contents: [String: Any] = ["images": [["filename": "\(name).png", "idiom": "universal"]], "info": ["author": "xcode", "version": 1]]
    try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("Contents.json"))
    print("Packaged \(name): \(side)px")
}

// A reviewable looping preview of the same four runtime frames.
let preview = URL(fileURLWithPath: "design/brand/animation/thinking-preview.gif")
let gif = CGImageDestinationCreateWithURL(preview as CFURL, UTType.gif.identifier as CFString, 4, nil)!
CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
for (index, duration) in [0.65, 0.70, 0.16, 0.55].enumerated() {
    let frame = sheet.cropping(to: CGRect(x: (index % 2) * side, y: (index / 2) * side, width: side, height: side))!
    CGImageDestinationAddImage(gif, frame, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: duration]] as CFDictionary)
}
precondition(CGImageDestinationFinalize(gif))
