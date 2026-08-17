import AVFoundation
import UIKit

/// Camera to use for scanning.
enum BarcodeCameraDirection: Int {
    case back = 1
    case front = 2

    static func map(value: Int?) -> BarcodeCameraDirection { value == 2 ? .front : .back }

    var captureDevicePosition: AVCaptureDevice.Position { self == .front ? .front : .back }
}

/// Orientation the scanner screen should adapt to.
enum BarcodeScanOrientation: Int {
    case portrait = 1
    case landscape = 2
    case adaptive = 3

    static func map(value: Int?) -> BarcodeScanOrientation {
        switch value {
        case 1: return .portrait
        case 2: return .landscape
        default: return .adaptive
        }
    }

    var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        switch self {
        case .portrait: return .portrait
        case .landscape: return .landscape
        case .adaptive: return .all
        }
    }
}

/// Everything the scanner screen needs, decoded from the plugin call.
struct BarcodeScanParameters: Decodable {
    /// Text to display above the scanning zone.
    let scanInstructions: String
    /// Text for the scan button. `Nil` means the button is not shown and scanning starts right away.
    let scanButtonText: String?
    /// Camera to use for scanning.
    let cameraDirection: BarcodeCameraDirection
    /// Orientation the scanner screen should adapt to.
    let scanOrientation: BarcodeScanOrientation
    /// The formats to scan for. Empty means every supported format.
    let formats: [BarcodeFormat]
    /// Accessibility labels. `Nil` or empty means no label is set.
    let cancelButtonAccessibilityLabel: String?
    let torchButtonOnAccessibilityLabel: String?
    let torchButtonOffAccessibilityLabel: String?

    enum CodingKeys: CodingKey {
        case scanButton
        case scanInstructions
        case scanText
        case cameraDirection
        case scanOrientation
        case hint
        case hints
        case cancelButtonAccessibilityLabel
        case torchButtonOnAccessibilityLabel
        case torchButtonOffAccessibilityLabel
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        self.scanInstructions = try container.decodeIfPresent(String.self, forKey: .scanInstructions) ?? ""

        // the button is only shown when explicitly enabled, and its text is only read in that case.
        let scanButton = try container.decodeIfPresent(Bool.self, forKey: .scanButton) ?? false
        let scanText = try container.decodeIfPresent(String.self, forKey: .scanText) ?? ""
        self.scanButtonText = scanButton && !scanText.isEmpty ? scanText : nil

        self.cameraDirection = .map(value: try container.decodeIfPresent(Int.self, forKey: .cameraDirection))
        self.scanOrientation = .map(value: try container.decodeIfPresent(Int.self, forKey: .scanOrientation))

        // `hints` takes precedence over the single `hint`.
        let hints = try container.decodeIfPresent([Int].self, forKey: .hints)?.compactMap { BarcodeFormat(rawValue: $0) }
        let hint = try container.decodeIfPresent(Int.self, forKey: .hint).flatMap { BarcodeFormat(rawValue: $0) }
        if let hints, !hints.isEmpty {
            self.formats = hints
        } else if let hint {
            self.formats = [hint]
        } else {
            self.formats = []
        }

        self.cancelButtonAccessibilityLabel = try container.decodeIfPresent(String.self, forKey: .cancelButtonAccessibilityLabel)
        self.torchButtonOnAccessibilityLabel = try container.decodeIfPresent(String.self, forKey: .torchButtonOnAccessibilityLabel)
        self.torchButtonOffAccessibilityLabel = try container.decodeIfPresent(String.self, forKey: .torchButtonOffAccessibilityLabel)
    }

    /// The single requested format, when the request is unambiguous. Used to tell UPC-A from EAN-13.
    var singleRequestedFormat: BarcodeFormat? { self.formats.count == 1 ? self.formats.first : nil }
}
