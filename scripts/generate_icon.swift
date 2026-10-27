import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Package the approved portrait without changing its composition or character.
let source = CommandLine.arguments.dropFirst().first ?? "design/brand/code-pax-headset-source.png"
guard let input = CGImageSourceCreateWithURL(URL(fileURLWithPath: source) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(input, 0, nil) else {
    fatalError("Could not read the approved Code Pax portrait: \(source)")
}
precondition(image.width == image.height, "The approved app icon must be square")
func export(size: Int, to path: String) {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data:nil,width:size,height:size,bitsPerComponent:8,bytesPerRow:0,
                            space:colorSpace,bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(red:0.10,green:0.09,blue:0.13,alpha:1)
    context.fill(CGRect(x:0,y:0,width:size,height:size))
    context.interpolationQuality = .high
    context.draw(image,in:CGRect(x:0,y:0,width:size,height:size))
    let url = URL(fileURLWithPath:path)
    try! FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
    let output = CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil)!
    CGImageDestinationAddImage(output,context.makeImage()!,nil)
    precondition(CGImageDestinationFinalize(output),"Could not write \(path)")
    print("Generated \(size)px: \(path)")
}
export(size:1024,to:"CodexIPad/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
export(size:512,to:"CodexIPad/Assets.xcassets/CodePaxPortrait.imageset/CodePaxPortrait.png")
