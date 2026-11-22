import CoreImage
import Darwin
import Foundation
import ImageIO
import UIKit

struct CaptureImageDiagnostics: Codable {
    let fileType: String?
    let width: Int?
    let height: Int?
    let iso: [Double]?
    let exposureSeconds: Double?
    let orientation: Int?
    let byteCount: Int

    init(data: Data) {
        byteCount = data.count

        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            fileType = nil
            width = nil
            height = nil
            iso = nil
            exposureSeconds = nil
            orientation = nil
            return
        }

        fileType = CGImageSourceGetType(source) as String?

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any] ?? [:]
        width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
        height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue

        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        iso = (exif?[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?
            .map(\.doubleValue)
        exposureSeconds = (exif?[kCGImagePropertyExifExposureTime] as? NSNumber)?
            .doubleValue
    }
}

struct CaptureDiagnosticEntry: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let appVersion: String
    let iOSVersion: String
    let requestedFrameCount: Int
    let mergedFrameCount: Int
    let input: CaptureImageDiagnostics?
    let raw: CaptureImageDiagnostics?
    let output: CaptureImageDiagnostics
    let processingMilliseconds: Double
    let mergeBackend: String
    let outputScale: Double
    let thermalState: String
    var saveStatus: String
    var saveMessage: String?
}

private struct CaptureDiagnosticsReport: Codable {
    let schemaVersion: Int
    let generatedAt: Date
    let deviceModel: String
    let captures: [CaptureDiagnosticEntry]
}

final class CaptureDiagnosticsStore {
    private let queue = DispatchQueue(label: "tomka.camera.diagnostics")
    private var entries: [CaptureDiagnosticEntry] = []
    private let maximumEntries = 100

    @discardableResult
    func recordCapture(
        inputData: Data?,
        rawData: Data?,
        outputData: Data,
        requestedFrameCount: Int,
        mergedFrameCount: Int,
        processingMilliseconds: Double,
        mergeBackend: String,
        outputScale: CGFloat
    ) -> UUID {
        let entry = CaptureDiagnosticEntry(
            id: UUID(),
            timestamp: Date(),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            iOSVersion: UIDevice.current.systemVersion,
            requestedFrameCount: requestedFrameCount,
            mergedFrameCount: mergedFrameCount,
            input: inputData.map(CaptureImageDiagnostics.init(data:)),
            raw: rawData.map(CaptureImageDiagnostics.init(data:)),
            output: CaptureImageDiagnostics(data: outputData),
            processingMilliseconds: max(0, processingMilliseconds),
            mergeBackend: mergeBackend,
            outputScale: Double(outputScale),
            thermalState: Self.thermalStateName(ProcessInfo.processInfo.thermalState),
            saveStatus: "pending",
            saveMessage: nil
        )

        queue.sync {
            entries.append(entry)
            if entries.count > maximumEntries {
                entries.removeFirst(entries.count - maximumEntries)
            }
        }
        return entry.id
    }

    func recordSave(id: UUID?, success: Bool, message: String) {
        guard let id else { return }

        queue.sync {
            guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
            entries[index].saveStatus = success ? "saved" : "failed"
            entries[index].saveMessage = message
        }
    }

    func exportJSON() -> URL? {
        let snapshot = queue.sync { entries }
        let report = CaptureDiagnosticsReport(
            schemaVersion: 1,
            generatedAt: Date(),
            deviceModel: Self.deviceModelIdentifier(),
            captures: snapshot
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(report)
            let fileName = "TomkaCamera-Diagnostics-\(UUID().uuidString).json"
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(fileName, isDirectory: false)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private static func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private static func deviceModelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
    }
}
