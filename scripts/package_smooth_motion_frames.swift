import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Each 4x4 source contains two motions, eight frames per motion.
let character = CommandLine.arguments.dropFirst().first ?? "codex"
precondition(["codex", "claude"].contains(character), "Choose codex or claude")
let prefix = character == "codex" ? "CodePax" : "Claude"
let groups = [("focus", ["Thinking", "Reading"]), ("work", ["Typing", "Replying"]), ("rest", ["Celebrating", "Focusing"])]
let durations = [0.75, 0.60, 0.06, 0.075, 0.075, 0.06, 0.65, 0.60]

for (group, actions) in groups {
    let source = "design/brand/animation/\(character)-\(group)-sheet-v2.png"
    let input = CGImageSourceCreateWithURL(URL(fileURLWithPath: source) as CFURL, nil)!
    let sheet = CGImageSourceCreateImageAtIndex(input, 0, nil)!
    precondition(sheet.width == sheet.height && sheet.width >= 128)
    for (actionIndex, action) in actions.enumerated() {
        let preview = URL(fileURLWithPath: "design/brand/animation/\(character)-\(action.lowercased())-preview.gif")
        let gif = CGImageDestinationCreateWithURL(preview as CFURL, UTType.gif.identifier as CFString, 8, nil)!
        if action != "Celebrating" {
            CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        }
        for index in 0..<8 {
            let column = index % 4
            let row = actionIndex * 2 + index / 4
            let left = floor(Double(column * sheet.width) / 4)
            let top = floor(Double(row * sheet.height) / 4)
            let right = floor(Double((column + 1) * sheet.width) / 4)
            let bottom = floor(Double((row + 1) * sheet.height) / 4)
            let crop = sheet.cropping(to: CGRect(x: left, y: top, width: right - left, height: bottom - top))!
            let context = CGContext(data: nil, width: 216, height: 216, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.interpolationQuality = .high
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 216, height: 216))
            let image = context.makeImage()!
            let name = "\(prefix)\(action)\(index)"
            let directory = URL(fileURLWithPath: "CodePax/Assets.xcassets/\(name).imageset")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let output = CGImageDestinationCreateWithURL(directory.appendingPathComponent("\(name).png") as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(output, image, nil)
            precondition(CGImageDestinationFinalize(output))
            let metadata: [String: Any] = ["images": [["filename": "\(name).png", "idiom": "universal"]], "info": ["author": "xcode", "version": 1]]
            try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("Contents.json"))
            if action == "Focusing" && index == 0 {
                let portrait = URL(fileURLWithPath: "CodePax/Assets.xcassets/\(prefix)Portrait.imageset/\(prefix)Portrait.png")
                try Data(contentsOf: directory.appendingPathComponent("\(name).png")).write(to: portrait, options: .atomic)
            }
            CGImageDestinationAddImage(gif, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: durations[index]]] as CFDictionary)
            print("Packaged \(name): 216px")
        }
        precondition(CGImageDestinationFinalize(gif))
    }
}
