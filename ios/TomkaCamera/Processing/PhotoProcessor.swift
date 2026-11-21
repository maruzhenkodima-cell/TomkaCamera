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
    let outputScale: CGFloat
    let usedHighResolutionUpscale: Bool
    let processingDescription: String
}

enum PhotoProcessor {
    private static let maximumOutputPixels: CGFloat = 48_000_000
    private static let maximumUpscaleScale: CGFloat = 2.0

    private static let context = CIContext(options: [
        .cacheIntermediates: false
    ])

    // Load the precompiled Metal Core Image kernel. This avoids the deprecated
    // Core Image Kernel Language source initializer and compiles the shader at build time.
    private static let medianKernel: CIColorKernel? = {
        guard let url = Bundle.main.url(
            forResource: "PhotoKernels",
            withExtension: "ci.metallib"
        ), let data = try? Data(contentsOf: url) else {
            return nil
        }

        return try? CIColorKernel(
            functionName: "median3",
            fromMetalLibraryData: data
        )
    }()

    private struct AlignedFrame {
        let image: CIImage
        let translation: CGPoint
    }

    static func process(
        _ frameData: [Data],
        enableHighResolutionUpscale: Bool = true
    ) throws -> PhotoProcessingResult {
        guard let firstData = frameData.first,
              let originalImage = UIImage(data: firstData),
              let firstCIImage = CIImage(
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
                mergedFrameCount: 1,
                outputScale: 1,
                usedHighResolutionUpscale: false,
                processingDescription: "Одиночный кадр без объединения"
            )
        }

        let reference = normalized(firstCIImage)
        var alignedFrames: [AlignedFrame] = [
            AlignedFrame(
                image: reference,
                translation: .zero
            )
        ]

        for data in frameData.dropFirst() {
            guard let floatingImage = CIImage(
                data: data,
                options: [.applyOrientationProperty: true]
            ) else {
                continue
            }

            let floating = normalized(floatingImage)

            guard abs(reference.extent.width - floating.extent.width) < 2,
                  abs(reference.extent.height - floating.extent.height) < 2,
                  let alignment = alignment(
                    reference: reference,
                    floating: floating
                  ) else {
                continue
            }

            alignedFrames.append(
                AlignedFrame(
                    image: floating,
                    translation: alignment.translation
                )
            )
        }

        guard alignedFrames.count > 1 else {
            return PhotoProcessingResult(
                originalImage: originalImage,
                enhancedImage: originalImage,
                outputData: firstData,
                mergedFrameCount: 1,
                outputScale: 1,
                usedHighResolutionUpscale: false,
                processingDescription: "Кадры не удалось надёжно совместить; сохранён оригинал"
            )
        }

        let sourcePixels = reference.extent.width * reference.extent.height
        let safeScale = min(
            maximumUpscaleScale,
            sqrt(maximumOutputPixels / max(sourcePixels, 1))
        )

        let hasSubpixelInformation = alignedFrames.count == 3 &&
            containsUsefulSubpixelOffsets(alignedFrames)

        let outputScale: CGFloat
        if enableHighResolutionUpscale && hasSubpixelInformation && safeScale >= 1.15 {
            outputScale = safeScale
        } else {
            outputScale = 1
        }

        var transformedImages: [CIImage] = []
        transformedImages.reserveCapacity(alignedFrames.count)

        for frame in alignedFrames {
            let image: CIImage

            if outputScale > 1 {
                guard let upscaled = lanczosUpscale(frame.image, scale: outputScale) else {
                    throw ProcessingError.upscaleFailed
                }
                image = upscaled.transformed(
                    by: CGAffineTransform(
                        translationX: frame.translation.x * outputScale,
                        y: frame.translation.y * outputScale
                    )
                )
            } else {
                image = frame.image.transformed(
                    by: CGAffineTransform(
                        translationX: frame.translation.x,
                        y: frame.translation.y
                    )
                )
            }

            transformedImages.append(image)
        }

        guard var commonExtent = transformedImages.first?.extent else {
            throw ProcessingError.mergeFailed
        }

        for image in transformedImages.dropFirst() {
            commonExtent = commonExtent.intersection(image.extent)
        }

        // Round inward, not outward: expanding the intersection would sample
        // transparent pixels along the edges of translated frames.
        let safeMinX = ceil(commonExtent.minX)
        let safeMinY = ceil(commonExtent.minY)
        let safeMaxX = floor(commonExtent.maxX)
        let safeMaxY = floor(commonExtent.maxY)
        commonExtent = CGRect(
            x: safeMinX,
            y: safeMinY,
            width: max(0, safeMaxX - safeMinX),
            height: max(0, safeMaxY - safeMinY)
        )

        guard !commonExtent.isNull,
              !commonExtent.isEmpty,
              commonExtent.width >= 64,
              commonExtent.height >= 64 else {
            return PhotoProcessingResult(
                originalImage: originalImage,
                enhancedImage: originalImage,
                outputData: firstData,
                mergedFrameCount: 1,
                outputScale: 1,
                usedHighResolutionUpscale: false,
                processingDescription: "Слишком малая общая область; сохранён оригинал"
            )
        }

        let croppedImages = transformedImages.map { $0.cropped(to: commonExtent) }
        let mergedImage: CIImage

        if croppedImages.count == 3,
           let median = medianKernel?.apply(
            extent: commonExtent,
            arguments: croppedImages
           ) {
            mergedImage = median
        } else {
            guard let average = average(croppedImages, extent: commonExtent) else {
                throw ProcessingError.mergeFailed
            }
            mergedImage = average
        }

        let noiseReduction = CIFilter(name: "CINoiseReduction")
        noiseReduction?.setValue(mergedImage, forKey: kCIInputImageKey)
        noiseReduction?.setValue(
            outputScale > 1 ? 0.008 : 0.012,
            forKey: "inputNoiseLevel"
        )
        noiseReduction?.setValue(0.55, forKey: "inputSharpness")

        let denoised = noiseReduction?.outputImage ?? mergedImage

        let sharpen = CIFilter(name: "CISharpenLuminance")
        sharpen?.setValue(denoised, forKey: kCIInputImageKey)
        sharpen?.setValue(outputScale > 1 ? 0.55 : 0.8, forKey: "inputRadius")
        sharpen?.setValue(0.2, forKey: "inputSharpness")

        let finalImage = (sharpen?.outputImage ?? denoised).cropped(to: commonExtent)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()

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

        let sourceMetadata = metadata(from: firstData)
        let outputData = try jpegData(
            from: outputCGImage,
            quality: 0.97,
            preserving: sourceMetadata
        )

        let usedHighResolutionUpscale = outputScale > 1
        let processingDescription: String

        if usedHighResolutionUpscale {
            processingDescription = String(
                format: "Объединено %d кадра · Lanczos-увеличение %.2f× · медианное подавление выбросов",
                alignedFrames.count,
                outputScale
            )
        } else if alignedFrames.count == 3 {
            processingDescription = "Объединено 3 кадра · подавлены шум и одиночные артефакты"
        } else {
            processingDescription = String(
                format: "Объединено %d кадра · подавление шума",
                alignedFrames.count
            )
        }

        return PhotoProcessingResult(
            originalImage: originalImage,
            enhancedImage: enhancedImage,
            outputData: outputData,
            mergedFrameCount: alignedFrames.count,
            outputScale: outputScale,
            usedHighResolutionUpscale: usedHighResolutionUpscale,
            processingDescription: processingDescription
        )
    }

    private static func normalized(_ image: CIImage) -> CIImage {
        let extent = image.extent
        return image.transformed(
            by: CGAffineTransform(
                translationX: -extent.minX,
                y: -extent.minY
            )
        )
    }

    private static func alignment(
        reference: CIImage,
        floating: CIImage
    ) -> (translation: CGPoint, confidence: Float)? {
        guard let referenceThumbnail = thumbnail(for: reference),
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
                  observation.confidence >= 0.35 else {
                return nil
            }

            let transform = observation.alignmentTransform
            let scaleX = reference.extent.width / CGFloat(referenceThumbnail.width)
            let scaleY = reference.extent.height / CGFloat(referenceThumbnail.height)

            let translationX = transform.tx * scaleX
            let translationY = transform.ty * scaleY

            guard translationX.isFinite,
                  translationY.isFinite,
                  abs(translationX) < reference.extent.width * 0.05,
                  abs(translationY) < reference.extent.height * 0.05 else {
                return nil
            }

            return (
                CGPoint(x: translationX, y: translationY),
                observation.confidence
            )
        } catch {
            return nil
        }
    }

    private static func containsUsefulSubpixelOffsets(
        _ frames: [AlignedFrame]
    ) -> Bool {
        for frame in frames.dropFirst() {
            let xFraction = abs(frame.translation.x - frame.translation.x.rounded())
            let yFraction = abs(frame.translation.y - frame.translation.y.rounded())

            let xDistanceToInteger = min(xFraction, 1 - xFraction)
            let yDistanceToInteger = min(yFraction, 1 - yFraction)

            if max(xDistanceToInteger, yDistanceToInteger) >= 0.18 {
                return true
            }
        }

        return false
    }

    private static func thumbnail(for image: CIImage) -> CGImage? {
        let extent = image.extent
        let maximumDimension: CGFloat = 2048
        let scale = min(
            1,
            maximumDimension / max(extent.width, extent.height)
        )

        let resized = image.transformed(
            by: CGAffineTransform(scaleX: scale, y: scale)
        )

        return context.createCGImage(
            resized,
            from: resized.extent.integral
        )
    }

    private static func lanczosUpscale(
        _ image: CIImage,
        scale: CGFloat
    ) -> CIImage? {
        guard let filter = CIFilter(name: "CILanczosScaleTransform") else {
            return nil
        }

        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(Float(scale), forKey: "inputScale")
        filter.setValue(1.0, forKey: "inputAspectRatio")

        return filter.outputImage
    }

    private static func average(
        _ images: [CIImage],
        extent: CGRect
    ) -> CIImage? {
        guard !images.isEmpty else { return nil }

        let weight = 1.0 / CGFloat(images.count)
        var composite: CIImage?

        for image in images {
            guard let weighted = weightedImage(image, weight: weight) else {
                return nil
            }

            if let current = composite {
                guard let addition = CIFilter(name: "CIAdditionCompositing") else {
                    return nil
                }
                addition.setValue(weighted, forKey: kCIInputImageKey)
                addition.setValue(current, forKey: kCIInputBackgroundImageKey)

                guard let output = addition.outputImage else {
                    return nil
                }
                composite = output
            } else {
                composite = weighted
            }
        }

        return composite?.cropped(to: extent)
    }

    private static func weightedImage(
        _ image: CIImage,
        weight: CGFloat
    ) -> CIImage? {
        guard let matrix = CIFilter(name: "CIColorMatrix") else {
            return nil
        }

        matrix.setValue(image, forKey: kCIInputImageKey)
        matrix.setValue(
            CIVector(x: weight, y: 0, z: 0, w: 0),
            forKey: "inputRVector"
        )
        matrix.setValue(
            CIVector(x: 0, y: weight, z: 0, w: 0),
            forKey: "inputGVector"
        )
        matrix.setValue(
            CIVector(x: 0, y: 0, z: weight, w: 0),
            forKey: "inputBVector"
        )
        matrix.setValue(
            CIVector(x: 0, y: 0, z: 0, w: 1),
            forKey: "inputAVector"
        )

        return matrix.outputImage
    }

    private static func metadata(from data: Data) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any] else {
            return [:]
        }

        return properties
    }

    private static func jpegData(
        from image: CGImage,
        quality: CGFloat,
        preserving sourceMetadata: [CFString: Any]
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

        var metadata = sourceMetadata
        metadata[kCGImagePropertyOrientation] = 1
        metadata[kCGImagePropertyPixelWidth] = image.width
        metadata[kCGImagePropertyPixelHeight] = image.height

        if var exif = metadata[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = image.width
            exif[kCGImagePropertyExifPixelYDimension] = image.height
            metadata[kCGImagePropertyExifDictionary] = exif
        }

        metadata[kCGImageDestinationLossyCompressionQuality] = quality

        CGImageDestinationAddImage(
            destination,
            image,
            metadata as CFDictionary
        )

        guard CGImageDestinationFinalize(destination) else {
            throw ProcessingError.encodingFailed
        }

        return data as Data
    }

    private enum ProcessingError: Error {
        case invalidImage
        case mergeFailed
        case upscaleFailed
        case renderFailed
        case encodingFailed
    }
}
