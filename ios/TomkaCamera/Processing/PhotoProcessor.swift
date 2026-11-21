import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Vision
import UIKit

struct PhotoProcessingResult {
    let originalImage: UIImage
    let enhancedImage: UIImage
    let outputData: Data
    let mergedFrameCount: Int
}

enum PhotoProcessor {
    private static let context = CIContext(options: [
        .cacheIntermediates: false
    ])

    static func process(_ frameData: [Data]) throws -> PhotoProcessingResult {
        guard let firstData = frameData.first,
              let originalImage = UIImage(data: firstData),
              let reference = CIImage(
                data: firstData,
                options: [.applyOrientationProperty: true]
              ) else {
            throw ProcessingError.invalidImage
        }

        guard frameData.count > 1 else {
            return PhotoProcessingResult(
                originalImage: originalImage,
                enhancedImage: originalImage,
                outputData: firstData,
                mergedFrameCount: 1
            )
        }

        var alignedImages: [CIImage] = [reference]

        for data in frameData.dropFirst() {
            guard let floating = CIImage(
                data: data,
                options: [.applyOrientationProperty: true]
            ) else {
                continue
            }

            guard let transform = alignmentTransform(
                reference: reference,
                floating: floating
            ) else {
                continue
            }

            alignedImages.append(floating.transformed(by: transform))
        }

        guard alignedImages.count > 1 else {
            return PhotoProcessingResult(
                originalImage: originalImage,
                enhancedImage: originalImage,
                outputData: firstData,
                mergedFrameCount: 1
            )
        }

        var commonExtent = alignedImages[0].extent
        for image in alignedImages.dropFirst() {
            commonExtent = commonExtent.intersection(image.extent)
        }

        commonExtent = commonExtent.integral
        guard !commonExtent.isNull,
              !commonExtent.isEmpty,
              commonExtent.width >= 64,
              commonExtent.height >= 64 else {
            return PhotoProcessingResult(
                originalImage: originalImage,
                enhancedImage: originalImage,
                outputData: firstData,
                mergedFrameCount: 1
            )
        }

        let weight = 1.0 / Float(alignedImages.count)
        var composite: CIImage?

        for image in alignedImages {
            guard let weighted = weightedImage(
                image.cropped(to: commonExtent),
                weight: weight
            ) else {
                continue
            }

            if let current = composite {
                let addition = CIFilter(name: "CIAdditionCompositing")
                addition?.setValue(weighted, forKey: kCIInputImageKey)
                addition?.setValue(current, forKey: kCIInputBackgroundImageKey)
                composite = addition?.outputImage
            } else {
                composite = weighted
            }
        }

        guard let averaged = composite?.cropped(to: commonExtent) else {
            throw ProcessingError.mergeFailed
        }

        let noiseReduction = CIFilter.noiseReduction()
        noiseReduction.inputImage = averaged
        noiseReduction.noiseLevel = 0.012
        noiseReduction.sharpness = 0.4

        let sharpen = CIFilter.sharpenLuminance()
        sharpen.inputImage = noiseReduction.outputImage ?? averaged
        sharpen.radius = 0.8
        sharpen.sharpness = 0.25

        let finalImage = sharpen.outputImage ?? averaged
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

        guard let outputCGImage = context.createCGImage(
            finalImage,
            from: commonExtent,
            format: .RGBA8,
            colorSpace: colorSpace
        ) else {
            throw ProcessingError.renderFailed
        }

        let enhancedImage = UIImage(
            cgImage: outputCGImage,
            scale: 1,
            orientation: .up
        )

        let outputData = try jpegData(
            from: outputCGImage,
            quality: 0.97
        )

        return PhotoProcessingResult(
            originalImage: originalImage,
            enhancedImage: enhancedImage,
            outputData: outputData,
            mergedFrameCount: alignedImages.count
        )
    }

    private static func alignmentTransform(
        reference: CIImage,
        floating: CIImage
    ) -> CGAffineTransform? {
        guard abs(reference.extent.width - floating.extent.width) < 2,
              abs(reference.extent.height - floating.extent.height) < 2,
              let referenceThumbnail = thumbnail(for: reference),
              let floatingThumbnail = thumbnail(for: floating) else {
            return nil
        }

        let request = VNTranslationalImageRegistrationRequest(
            targetedCGImage: floatingThumbnail,
            options: [:]
        )

        do {
            let handler = VNImageRequestHandler(
                cgImage: referenceThumbnail,
                options: [:]
            )
            try handler.perform([request])

            guard let observation = request.results?.first
                    as? VNImageTranslationAlignmentObservation,
                  observation.confidence >= 0.15 else {
                return nil
            }

            let transform = observation.alignmentTransform
            let scaleX = reference.extent.width / CGFloat(referenceThumbnail.width)
            let scaleY = reference.extent.height / CGFloat(referenceThumbnail.height)

            let translationX = transform.tx * scaleX
            let translationY = transform.ty * scaleY

            guard translationX.isFinite,
                  translationY.isFinite,
                  abs(translationX) < reference.extent.width * 0.08,
                  abs(translationY) < reference.extent.height * 0.08 else {
                return nil
            }

            return CGAffineTransform(
                a: transform.a,
                b: transform.b,
                c: transform.c,
                d: transform.d,
                tx: translationX,
                ty: translationY
            )
        } catch {
            return nil
        }
    }

    private static func thumbnail(for image: CIImage) -> CGImage? {
        let extent = image.extent
        let maximumDimension: CGFloat = 1024
        let scale = min(
            1,
            maximumDimension / max(extent.width, extent.height)
        )

        let resized = image.transformed(
            by: CGAffineTransform(scaleX: scale, y: scale)
        )
        return context.createCGImage(resized, from: resized.extent.integral)
    }

    private static func weightedImage(
        _ image: CIImage,
        weight: Float
    ) -> CIImage? {
        guard let matrix = CIFilter(name: "CIColorMatrix") else {
            return nil
        }

        matrix.setValue(image, forKey: kCIInputImageKey)
        matrix.setValue(
            CIVector(x: CGFloat(weight), y: 0, z: 0, w: 0),
            forKey: "inputRVector"
        )
        matrix.setValue(
            CIVector(x: 0, y: CGFloat(weight), z: 0, w: 0),
            forKey: "inputGVector"
        )
        matrix.setValue(
            CIVector(x: 0, y: 0, z: CGFloat(weight), w: 0),
            forKey: "inputBVector"
        )
        matrix.setValue(
            CIVector(x: 0, y: 0, z: 0, w: 1),
            forKey: "inputAVector"
        )

        return matrix.outputImage
    }

    private static func jpegData(
        from image: CGImage,
        quality: CGFloat
    ) throws -> Data {
        let data = NSMutableData()

        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw ProcessingError.encodingFailed
        }

        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )

        guard CGImageDestinationFinalize(destination) else {
            throw ProcessingError.encodingFailed
        }

        return data as Data
    }

    private enum ProcessingError: Error {
        case invalidImage
        case mergeFailed
        case renderFailed
        case encodingFailed
    }
}
