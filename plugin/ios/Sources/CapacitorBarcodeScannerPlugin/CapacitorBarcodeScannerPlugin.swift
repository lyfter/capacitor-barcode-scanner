import AVFoundation
import Capacitor
import Foundation

@objc(CapacitorBarcodeScannerPlugin)
public class CapacitorBarcodeScannerPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "CapacitorBarcodeScannerPlugin"
    public let jsName = "CapacitorBarcodeScanner"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "scanBarcode", returnType: CAPPluginReturnPromise)
    ]

    @objc func scanBarcode(_ call: CAPPluginCall) {
        guard let argumentsData = try? JSONSerialization.data(withJSONObject: call.jsObjectRepresentation),
              let parameters = try? JSONDecoder().decode(BarcodeScanParameters.self, from: argumentsData) else {
            call.sendError(with: .scanInputArgumentsIssue)
            return
        }

        self.requestCameraAccess { granted in
            guard granted else { return call.sendError(with: .cameraAccessDenied) }
            self.presentScanner(with: parameters, for: call)
        }
    }
}

// MARK: - Private methods
private extension CapacitorBarcodeScannerPlugin {
    /// Verifies the app's authorisation to the device's camera, requesting it if it hasn't been asked yet.
    /// - Parameter completion: Called on the main thread with the resulting authorisation.
    func requestCameraAccess(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            DispatchQueue.main.async { completion(true) }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            DispatchQueue.main.async { completion(false) }
        }
    }

    func presentScanner(with parameters: BarcodeScanParameters, for call: CAPPluginCall) {
        guard let viewController = self.bridge?.viewController else {
            call.sendError(with: .bridgeNotInitialized)
            return
        }

        let scannerViewController = BarcodeScannerViewController(parameters: parameters) { outcome in
            switch outcome {
            case .scanned(let text, let format):
                call.resolve(["ScanResult": text, "format": format.rawValue])
            case .cancelled:
                call.sendError(with: .scanningCancelled)
            case .failed(let error):
                call.sendError(with: error)
            }
        }
        scannerViewController.modalPresentationStyle = .fullScreen
        viewController.present(scannerViewController, animated: true)
    }
}

extension CAPPluginCall {

    func sendError(with error: BarcodeError) {
        self.reject(error.errorDescription, error.errorCode)
    }

}
