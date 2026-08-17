import AudioToolbox
import AVFoundation
import UIKit

/// The outcome of presenting the scanner screen.
enum BarcodeScanOutcome {
    case scanned(text: String, format: BarcodeFormat)
    case cancelled
    case failed(BarcodeError)
}

/// Full screen barcode scanner built directly on AVFoundation.
/// `AVCaptureMetadataOutput` natively takes a list of symbologies, so only the requested formats
/// are ever detected - anything else in front of the camera is ignored and scanning continues.
final class BarcodeScannerViewController: UIViewController {

    private enum Layout {
        static let mainColour: UIColor = .white
        static let dimmingColour: UIColor = UIColor.black.withAlphaComponent(0.65)
        static let cornerRadius: CGFloat = 4.0
        static let lineWidth: CGFloat = 1.0
        static let screenPadding: CGFloat = 32.0
        static let smallerPadding: CGFloat = 16.0
        static let buttonSize: CGFloat = 44.0
        /// Fraction of the shortest screen edge used for the scanning zone's width.
        static let scanZoneWidthRatio: CGFloat = 0.85
        /// The scanning zone's height, as a fraction of its width.
        static let scanZoneAspectRatio: CGFloat = 0.62
    }

    private let parameters: BarcodeScanParameters
    private let completion: (BarcodeScanOutcome) -> Void
    /// Guards against reporting an outcome more than once.
    private var hasFinished = false

    private let session = AVCaptureSession()
    private let metadataOutput = AVCaptureMetadataOutput()
    private let sessionQueue = DispatchQueue(label: "com.capacitorjs.barcodescanner.session")
    private var captureDevice: AVCaptureDevice?
    private var previewLayer: AVCaptureVideoPreviewLayer?

    /// Detection is only processed once enabled. Without a scan button, it is enabled from the start.
    private var isScanningEnabled: Bool
    private var isTorchOn = false

    private let dimmingLayer = CAShapeLayer()
    private let scanZoneView = UIView()
    private let instructionsLabel = UILabel()
    private lazy var torchButton = UIButton(type: .system)
    private lazy var scanButton = UIButton(type: .system)

    init(parameters: BarcodeScanParameters, completion: @escaping (BarcodeScanOutcome) -> Void) {
        self.parameters = parameters
        self.completion = completion
        self.isScanningEnabled = parameters.scanButtonText == nil
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        self.parameters.scanOrientation.supportedInterfaceOrientations
    }

    override var prefersStatusBarHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        self.view.backgroundColor = .black
        self.setUpUI()

        do {
            try self.configureSession()
        } catch let error as BarcodeError {
            return self.finish(with: .failed(error))
        } catch {
            return self.finish(with: .failed(.scanningError))
        }

        self.torchButton.isHidden = !self.captureDeviceHasTorch
        self.sessionQueue.async { self.session.startRunning() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        self.setTorch(on: false)
        self.sessionQueue.async { self.session.stopRunning() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        self.previewLayer?.frame = self.view.bounds
        self.updateVideoOrientation()
        self.updateDimmingMask()
        // Restrict detection to the scanning zone, so a code outside it is not picked up.
        if let previewLayer = self.previewLayer, !self.scanZoneView.frame.isEmpty {
            self.metadataOutput.rectOfInterest = previewLayer.metadataOutputRectConverted(fromLayerRect: self.scanZoneView.frame)
        }
    }
}

// MARK: - Session set up
private extension BarcodeScannerViewController {
    func configureSession() throws {
        guard let device = AVCaptureDevice.default(
            .builtInWideAngleCamera, for: .video, position: self.parameters.cameraDirection.captureDevicePosition
        ) ?? AVCaptureDevice.default(for: .video) else { throw BarcodeError.scanningError }
        self.captureDevice = device

        let input = try AVCaptureDeviceInput(device: device)

        self.session.beginConfiguration()
        defer { self.session.commitConfiguration() }

        guard self.session.canAddInput(input), self.session.canAddOutput(self.metadataOutput) else {
            throw BarcodeError.scanningError
        }
        self.session.addInput(input)
        self.session.addOutput(self.metadataOutput)

        // `metadataObjectTypes` may only contain types the output actually supports on this device,
        // so the requested formats are intersected with what is available.
        let requestedTypes = BarcodeFormat.metadataObjectTypes(for: self.parameters.formats)
        let availableTypes = self.metadataOutput.availableMetadataObjectTypes
        let supportedTypes = requestedTypes.filter { availableTypes.contains($0) }
        guard !supportedTypes.isEmpty else { throw BarcodeError.scanInputArgumentsIssue }
        if supportedTypes.count < requestedTypes.count {
            let unsupported = requestedTypes.filter { !availableTypes.contains($0) }
            print("Warning (Barcode Plugin): these formats are not supported on this device and will not be scanned: \(unsupported).")
        }
        self.metadataOutput.setMetadataObjectsDelegate(self, queue: .main)
        self.metadataOutput.metadataObjectTypes = supportedTypes

        let previewLayer = AVCaptureVideoPreviewLayer(session: self.session)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.frame = self.view.bounds
        self.view.layer.insertSublayer(previewLayer, at: 0)
        self.previewLayer = previewLayer
    }

    func updateVideoOrientation() {
        guard let connection = self.previewLayer?.connection else { return }
        let interfaceOrientation = self.view.window?.windowScene?.interfaceOrientation ?? .portrait
        if #available(iOS 17.0, *) {
            let angle: CGFloat
            switch interfaceOrientation {
            case .landscapeLeft: angle = 180
            case .landscapeRight: angle = 0
            case .portraitUpsideDown: angle = 270
            default: angle = 90
            }
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
        } else if connection.isVideoOrientationSupported {
            switch interfaceOrientation {
            case .landscapeLeft: connection.videoOrientation = .landscapeLeft
            case .landscapeRight: connection.videoOrientation = .landscapeRight
            case .portraitUpsideDown: connection.videoOrientation = .portraitUpsideDown
            default: connection.videoOrientation = .portrait
            }
        }
    }
}

// MARK: - Detection
extension BarcodeScannerViewController: AVCaptureMetadataOutputObjectsDelegate {
    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard self.isScanningEnabled, !self.hasFinished else { return }
        guard let object = metadataObjects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject }).first,
              let payload = object.stringValue, !payload.isEmpty else { return }

        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        let format = BarcodeFormat.from(object.type, requestedFormat: self.parameters.singleRequestedFormat)
        self.finish(with: .scanned(text: payload, format: format))
    }

    func finish(with outcome: BarcodeScanOutcome) {
        guard !self.hasFinished else { return }
        self.hasFinished = true
        self.setTorch(on: false)
        self.sessionQueue.async { self.session.stopRunning() }
        self.dismiss(animated: true) { self.completion(outcome) }
    }
}

// MARK: - UI
private extension BarcodeScannerViewController {
    func setUpUI() {
        self.dimmingLayer.fillColor = Layout.dimmingColour.cgColor
        self.dimmingLayer.fillRule = .evenOdd
        self.view.layer.addSublayer(self.dimmingLayer)

        self.scanZoneView.translatesAutoresizingMaskIntoConstraints = false
        self.scanZoneView.layer.borderColor = Layout.mainColour.cgColor
        self.scanZoneView.layer.borderWidth = Layout.lineWidth
        self.scanZoneView.layer.cornerRadius = Layout.cornerRadius
        self.scanZoneView.isUserInteractionEnabled = false
        self.view.addSubview(self.scanZoneView)

        self.instructionsLabel.translatesAutoresizingMaskIntoConstraints = false
        self.instructionsLabel.text = self.parameters.scanInstructions
        self.instructionsLabel.textColor = Layout.mainColour
        self.instructionsLabel.textAlignment = .center
        self.instructionsLabel.numberOfLines = 0
        self.instructionsLabel.font = .preferredFont(forTextStyle: .body)
        self.instructionsLabel.adjustsFontForContentSizeCategory = true
        self.view.addSubview(self.instructionsLabel)

        let cancelButton = self.makeIconButton(systemName: "xmark")
        cancelButton.accessibilityLabel = self.parameters.cancelButtonAccessibilityLabel?.nilWhenEmpty
        cancelButton.addTarget(self, action: #selector(self.cancelButtonTapped), for: .touchUpInside)
        self.view.addSubview(cancelButton)

        self.torchButton = self.makeIconButton(systemName: "flashlight.off.fill")
        self.torchButton.addTarget(self, action: #selector(self.torchButtonTapped), for: .touchUpInside)
        // the capture device is only known once the session is configured, so the button starts hidden.
        self.torchButton.isHidden = true
        self.updateTorchButton()
        self.view.addSubview(self.torchButton)

        NSLayoutConstraint.activate([
            cancelButton.topAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.topAnchor, constant: Layout.smallerPadding),
            cancelButton.trailingAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.trailingAnchor, constant: -Layout.screenPadding),

            self.scanZoneView.centerXAnchor.constraint(equalTo: self.view.centerXAnchor),
            self.scanZoneView.centerYAnchor.constraint(equalTo: self.view.centerYAnchor),
            self.scanZoneView.widthAnchor.constraint(
                equalTo: self.view.widthAnchor, multiplier: Layout.scanZoneWidthRatio
            ).withPriority(.defaultHigh),
            self.scanZoneView.widthAnchor.constraint(lessThanOrEqualTo: self.view.heightAnchor, multiplier: Layout.scanZoneWidthRatio),
            self.scanZoneView.heightAnchor.constraint(equalTo: self.scanZoneView.widthAnchor, multiplier: Layout.scanZoneAspectRatio),

            self.instructionsLabel.bottomAnchor.constraint(equalTo: self.scanZoneView.topAnchor, constant: -Layout.screenPadding),
            self.instructionsLabel.leadingAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.leadingAnchor, constant: Layout.screenPadding),
            self.instructionsLabel.trailingAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.trailingAnchor, constant: -Layout.screenPadding),

            self.torchButton.bottomAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.bottomAnchor, constant: -Layout.screenPadding),
            self.torchButton.trailingAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.trailingAnchor, constant: -Layout.screenPadding)
        ])

        guard let scanButtonText = self.parameters.scanButtonText else { return }
        self.scanButton.translatesAutoresizingMaskIntoConstraints = false
        self.scanButton.setTitle(scanButtonText, for: .normal)
        self.scanButton.setTitleColor(Layout.mainColour, for: .normal)
        self.scanButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        self.scanButton.titleLabel?.adjustsFontForContentSizeCategory = true
        self.scanButton.contentEdgeInsets = .init(top: 12.0, left: 24.0, bottom: 12.0, right: 24.0)
        self.scanButton.layer.borderColor = Layout.mainColour.cgColor
        self.scanButton.layer.borderWidth = Layout.lineWidth
        self.scanButton.layer.cornerRadius = Layout.cornerRadius
        self.scanButton.addTarget(self, action: #selector(self.scanButtonTapped), for: .touchUpInside)
        self.view.addSubview(self.scanButton)

        NSLayoutConstraint.activate([
            self.scanButton.centerXAnchor.constraint(equalTo: self.view.centerXAnchor),
            self.scanButton.bottomAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.bottomAnchor, constant: -Layout.screenPadding)
        ])
    }

    func makeIconButton(systemName: String) -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setImage(UIImage(systemName: systemName), for: .normal)
        button.tintColor = Layout.mainColour
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: Layout.buttonSize),
            button.heightAnchor.constraint(equalToConstant: Layout.buttonSize)
        ])
        return button
    }

    /// Redraws the dimming overlay so that only the scanning zone is left clear.
    func updateDimmingMask() {
        self.dimmingLayer.frame = self.view.bounds
        let path = UIBezierPath(rect: self.view.bounds)
        path.append(UIBezierPath(roundedRect: self.scanZoneView.frame, cornerRadius: Layout.cornerRadius))
        self.dimmingLayer.path = path.cgPath
    }

    var captureDeviceHasTorch: Bool { self.captureDevice?.hasTorch ?? false }

    func updateTorchButton() {
        let iconName = self.isTorchOn ? "flashlight.on.fill" : "flashlight.off.fill"
        self.torchButton.setImage(UIImage(systemName: iconName), for: .normal)
        let label = self.isTorchOn
            ? self.parameters.torchButtonOnAccessibilityLabel
            : self.parameters.torchButtonOffAccessibilityLabel
        self.torchButton.accessibilityLabel = label?.nilWhenEmpty
    }

    func setTorch(on: Bool) {
        guard let device = self.captureDevice, device.hasTorch, device.isTorchAvailable else { return }
        guard on != self.isTorchOn else { return }
        do {
            try device.lockForConfiguration()
            device.torchMode = on ? .on : .off
            device.unlockForConfiguration()
            self.isTorchOn = on
            self.updateTorchButton()
        } catch {
            print("Warning (Barcode Plugin): could not toggle the torch - \(error.localizedDescription).")
        }
    }

    @objc func cancelButtonTapped() {
        self.finish(with: .cancelled)
    }

    @objc func torchButtonTapped() {
        self.setTorch(on: !self.isTorchOn)
    }

    @objc func scanButtonTapped() {
        self.isScanningEnabled.toggle()
        self.scanButton.alpha = self.isScanningEnabled ? 0.5 : 1.0
        if self.isScanningEnabled {
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        }
    }
}

private extension NSLayoutConstraint {
    func withPriority(_ priority: UILayoutPriority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}

private extension String {
    /// An empty accessibility label means "no label", matching the plugin's documented behaviour.
    var nilWhenEmpty: String? { self.isEmpty ? nil : self }
}
