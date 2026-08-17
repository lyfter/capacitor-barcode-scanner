import AVFoundation

/// The barcode formats the plugin can be asked to scan.
/// Raw values match `CapacitorBarcodeScannerTypeHint` on the JavaScript side, so they can be
/// decoded from, and reported back in, the plugin call without any translation.
enum BarcodeFormat: Int, CaseIterable {
    case qrCode = 0
    case aztec
    case codabar
    case code39
    case code93
    case code128
    case dataMatrix
    case maxicode
    case itf
    case ean13
    case ean8
    case pdf417
    case rss14
    case rssExpanded
    case upcA
    case upcE
    case upcEanExtension
    case unknown    // `ALL` on the JavaScript side: every supported format is scanned.

    /// The metadata object types AVFoundation should look for to detect this format.
    /// An empty array means AVFoundation cannot detect the format at all.
    var metadataObjectTypes: [AVMetadataObject.ObjectType] {
        switch self {
        case .qrCode: return [.qr]
        case .aztec: return [.aztec]
        case .codabar:
            guard #available(iOS 15.4, *) else { return [] }
            return [.codabar]
        case .code39: return [.code39, .code39Mod43]
        case .code93: return [.code93]
        case .code128: return [.code128]
        case .dataMatrix: return [.dataMatrix]
        case .itf: return [.itf14, .interleaved2of5]
        case .ean13: return [.ean13]
        case .ean8: return [.ean8]
        case .pdf417: return [.pdf417]
        case .rss14: return Self.gs1DataBarTypes(expanded: false)
        case .rssExpanded: return Self.gs1DataBarTypes(expanded: true)
        // UPC-A is a subset of EAN-13 and AVFoundation reports it as such, zero-padded to 13 digits.
        case .upcA: return [.ean13]
        case .upcE: return [.upce]
        // Not detectable by AVFoundation.
        case .maxicode, .upcEanExtension: return []
        case .unknown: return Self.allMetadataObjectTypes
        }
    }

    /// Every metadata object type the plugin knows about, used when no format is requested.
    static let allMetadataObjectTypes: [AVMetadataObject.ObjectType] = {
        var result = BarcodeFormat.allCases
            .filter { $0 != .unknown }
            .flatMap { $0.metadataObjectTypes }
        if #available(iOS 15.4, *) {
            result += [.microQR, .microPDF417]
        }
        return result.deduplicated()
    }()

    /// Maps the requested formats into the metadata object types to scan for.
    /// An empty list, or one containing `unknown` (`ALL`), means every supported format is scanned.
    static func metadataObjectTypes(for formats: [BarcodeFormat]) -> [AVMetadataObject.ObjectType] {
        guard !formats.isEmpty, !formats.contains(.unknown) else { return Self.allMetadataObjectTypes }
        return formats.flatMap { $0.metadataObjectTypes }.deduplicated()
    }

    /// Maps a detected metadata object type back into the format to report to the caller.
    /// - Parameters:
    ///   - objectType: The type AVFoundation detected.
    ///   - requestedFormat: The single requested format, when there is one. AVFoundation cannot tell
    ///   UPC-A and EAN-13 apart, so an unambiguous request is what decides which of the two is reported.
    static func from(_ objectType: AVMetadataObject.ObjectType, requestedFormat: BarcodeFormat? = nil) -> BarcodeFormat {
        if objectType == .ean13, requestedFormat == .upcA { return .upcA }
        if #available(iOS 15.4, *) {
            if objectType == .microQR { return .qrCode }
            if objectType == .microPDF417 { return .pdf417 }
        }
        return BarcodeFormat.allCases.first {
            $0 != .unknown && $0 != .upcA && $0.metadataObjectTypes.contains(objectType)
        } ?? .unknown
    }

    private static func gs1DataBarTypes(expanded: Bool) -> [AVMetadataObject.ObjectType] {
        guard #available(iOS 15.4, *) else { return [] }
        return expanded ? [.gs1DataBarExpanded] : [.gs1DataBar, .gs1DataBarLimited]
    }
}

private extension Array where Element: Equatable {
    /// Removes duplicates while keeping the original order.
    func deduplicated() -> [Element] {
        var result: [Element] = []
        for element in self where !result.contains(element) {
            result.append(element)
        }
        return result
    }
}
