import XCTest
import UIKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
@testable import CodePax

final class AvatarCustomizationTests: XCTestCase {
    private func image(_ color: UIColor, width: Int = 128, height: Int = 128) -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            color.setFill(); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }
    private func gif(count: Int = 3) throws -> Data {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, count, nil))
        for index in 0..<count {
            let frame = try XCTUnwrap(image(index % 2 == 0 ? .red : .blue).cgImage)
            CGImageDestinationAddImage(destination, frame, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: index == 1 ? 0.12 : 0.4]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
    func testSpriteSheetSplitsInReadingOrderAndPreservesTransparency() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false
        let sheet = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256), format: format).image { context in
            for (index, color) in [UIColor.red, .green, .blue, .yellow].enumerated() {
                color.setFill(); context.fill(CGRect(x: index % 2 * 128, y: index / 2 * 128, width: 128, height: 128))
            }
        }
        let decoded = try AvatarMedia.decode(try XCTUnwrap(sheet.pngData()), kind: .animation)
        XCTAssertEqual(decoded.frames.count, 4)
        XCTAssertEqual(decoded.durations.count, 4)
        let samples = try decoded.frames.map { image -> [UInt8] in
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(try XCTUnwrap(image.cgImage), in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: 4))
        }
        XCTAssertGreaterThan(samples[0][0], 240); XCTAssertLessThan(samples[0][1], 10)
        XCTAssertGreaterThan(samples[1][1], 240); XCTAssertLessThan(samples[1][0], 10)
        XCTAssertGreaterThan(samples[2][2], 240); XCTAssertLessThan(samples[2][0], 10)
        XCTAssertGreaterThan(samples[3][0], 240); XCTAssertGreaterThan(samples[3][1], 240)
        let transparent = UIGraphicsImageRenderer(size: CGSize(width: 128, height: 128), format: format).image { _ in }
        let portrait = try AvatarMedia.decode(try XCTUnwrap(transparent.pngData()), kind: .portrait)
        XCTAssertNotEqual(portrait.frames[0].cgImage?.alphaInfo, CGImageAlphaInfo.noneSkipLast)
    }
    func testGIFDelaysFrameLimitsAndInvalidSpriteSheets() throws {
        let decoded = try AvatarMedia.decode(gif(), kind: .animation)
        XCTAssertEqual(decoded.frames.count, 3)
        XCTAssertEqual(decoded.durations[1], 0.12, accuracy: 0.02)
        XCTAssertThrowsError(try AvatarMedia.decode(gif(count: 49), kind: .animation))
        XCTAssertThrowsError(try AvatarMedia.decode(Data("not an image".utf8), kind: .portrait))
        XCTAssertThrowsError(try AvatarMedia.decode(try XCTUnwrap(image(.red, width: 200, height: 128).pngData()), kind: .animation))
        XCTAssertThrowsError(try AvatarMedia.decode(Data(repeating: 0, count: AvatarMedia.maximumBytes + 1), kind: .portrait))
        XCTAssertEqual(AvatarFrameTiming.index(elapsed: 0.41, durations: decoded.durations, enabled: true), 1)
        XCTAssertEqual(AvatarFrameTiming.index(elapsed: 0.41, durations: decoded.durations, enabled: false), 0)
    }
    func testAPNGUsesEmbeddedAnimationFramesAndDelays() throws {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 2, nil))
        CGImageDestinationSetProperties(destination, [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: 0]] as CFDictionary)
        for color in [UIColor.red, .blue] {
            CGImageDestinationAddImage(destination, try XCTUnwrap(image(color).cgImage), [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: 0.25]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let decoded = try AvatarMedia.decode(data as Data, kind: .animation)
        XCTAssertEqual(decoded.frames.count, 2)
        XCTAssertEqual(decoded.durations[0], 0.25, accuracy: 0.02)
    }

    @MainActor
    func testImportedAssetsSurviveRelaunchFailedImportAndReset() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CustomAvatarStore(directory: directory)
        await store.importData(try XCTUnwrap(image(.red).pngData()), kind: .portrait)
        XCTAssertNotNil(store.appearance.portrait)
        XCTAssertNil(store.appearance.animation)
        await store.importData(try gif(), kind: .animation)
        XCTAssertEqual(store.appearance.animation?.frames.count, 3)
        let reloaded = CustomAvatarStore(directory: directory)
        XCTAssertNotNil(reloaded.appearance.portrait)
        XCTAssertEqual(reloaded.appearance.animation?.frames.count, 3)
        await store.importData(Data("broken".utf8), kind: .animation)
        XCTAssertNotNil(store.error)
        XCTAssertEqual(store.appearance.animation?.frames.count, 3)
        XCTAssertEqual(CustomAvatarStore(directory: directory).appearance.animation?.frames.count, 3)
        await store.reset()
        XCTAssertFalse(store.appearance.isCustom)
        XCTAssertFalse(CustomAvatarStore(directory: directory).appearance.isCustom)
    }
    @MainActor
    func testAnimationOnlyUsesItsFirstFrameForTheStaticPortrait() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CustomAvatarStore(directory: directory)
        await store.importData(try gif(), kind: .animation)
        XCTAssertNil(store.appearance.portrait)
        XCTAssertNotNil(store.appearance.displayPortrait)
        XCTAssertTrue(store.appearance.isCustom)
    }
}
