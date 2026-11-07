import SwiftUI
import AVFoundation

struct QRScannerView: View {
    @Environment(\.dismiss) private var dismiss
    let onResult: (String) -> Void
    let onFailure: (String) -> Void

    var body: some View {
        NavigationStack {
            CameraQRScanner(onResult: onResult, onFailure: onFailure)
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .bottom) {
                    Text("Наведите камеру на QR-код подписки или конфигурации")
                        .font(.callout).padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)).padding()
                }
                .navigationTitle("Сканировать QR")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } } }
        }
    }
}

private struct CameraQRScanner: UIViewControllerRepresentable {
    let onResult: (String) -> Void
    let onFailure: (String) -> Void
    func makeUIViewController(context: Context) -> CameraQRController {
        CameraQRController(onResult: onResult, onFailure: onFailure)
    }
    func updateUIViewController(_ controller: CameraQRController, context: Context) { }
}

private final class CameraQRController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.blink.qr-camera")
    private var preview: AVCaptureVideoPreviewLayer?
    private var visible = false
    private var completed = false
    // Accessed only on sessionQueue.
    private var configured = false
    private let onResult: (String) -> Void
    private let onFailure: (String) -> Void

    init(onResult: @escaping (String) -> Void, onFailure: @escaping (String) -> Void) {
        self.onResult = onResult; self.onFailure = onFailure
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        preview = layer
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
        if let orientation = view.window?.windowScene?.interfaceOrientation,
           let connection = preview?.connection, connection.isVideoOrientationSupported {
            switch orientation {
            case .landscapeLeft: connection.videoOrientation = .landscapeLeft
            case .landscapeRight: connection.videoOrientation = .landscapeRight
            case .portraitUpsideDown: connection.videoOrientation = .portraitUpsideDown
            default: connection.videoOrientation = .portrait
            }
        }
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        visible = true
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: startCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, self.visible else { return }
                    if granted { self.startCamera() } else { self.fail("Разрешите доступ к камере в настройках iOS для Blink или выберите QR из фото.") }
                }
            }
        default: fail("Разрешите доступ к камере в настройках iOS для Blink или выберите QR из фото.")
        }
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        visible = false
        stopCamera()
    }
    private func startCamera() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.configured {
                self.session.beginConfiguration()
                guard let camera = AVCaptureDevice.default(for: .video),
                      let input = try? AVCaptureDeviceInput(device: camera), self.session.canAddInput(input) else {
                    self.session.commitConfiguration()
                    DispatchQueue.main.async { self.fail("Камера недоступна. Выберите QR из фото или вставьте ссылку.") }
                    return
                }
                self.session.addInput(input)
                let output = AVCaptureMetadataOutput()
                guard self.session.canAddOutput(output) else {
                    self.session.commitConfiguration()
                    DispatchQueue.main.async { self.fail("Не удалось запустить сканирование QR.") }
                    return
                }
                self.session.addOutput(output)
                guard output.availableMetadataObjectTypes.contains(.qr) else {
                    self.session.commitConfiguration()
                    DispatchQueue.main.async { self.fail("Камера не поддерживает распознавание QR.") }
                    return
                }
                output.setMetadataObjectsDelegate(self, queue: .main)
                output.metadataObjectTypes = [.qr]
                self.session.commitConfiguration()
                self.configured = true
            }
            self.session.startRunning()
        }
    }
    private func stopCamera() {
        sessionQueue.async { [session] in if session.isRunning { session.stopRunning() } }
    }
    private func fail(_ message: String) {
        guard visible, !completed else { return }
        completed = true
        stopCamera()
        onFailure(message)
    }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard visible, !completed,
              let text = objects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first,
              !text.isEmpty else { return }
        completed = true
        stopCamera()
        onResult(text)
    }
}
