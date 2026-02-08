import SwiftUI
import AVFoundation

/// QR code scanner view — scans easy://pair?... URL for pairing
struct QRScannerView: View {
    let onPaired: (PairingInfo) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var isScanning = true

    var body: some View {
        NavigationStack {
            ZStack {
                QRCameraPreview(onCodeScanned: handleCode)
                    .ignoresSafeArea()

                VStack {
                    Spacer()

                    // Instructions
                    VStack(spacing: 8) {
                        Text("Scan the QR code from Mac terminal")
                            .font(.headline)
                            .foregroundStyle(.white)

                        Text("Displayed when running easy-server --relay")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))

                        if let error {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .padding(.top, 4)
                        }
                    }
                    .padding()
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding()
                }
            }
            .navigationTitle("Scan QR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func handleCode(_ code: String) {
        guard isScanning else { return }

        guard let url = URL(string: code),
              let info = PairingInfo(url: url) else {
            error = "Invalid QR code"
            return
        }

        isScanning = false
        onPaired(info)
        dismiss()
    }
}

// MARK: - Camera Preview

struct QRCameraPreview: UIViewRepresentable {
    let onCodeScanned: (String) -> Void

    func makeUIView(context: Context) -> CameraPreviewView {
        let view = CameraPreviewView()
        let session = AVCaptureSession()

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return view }

        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        session.addOutput(output)
        output.setMetadataObjectsDelegate(context.coordinator, queue: .main)
        output.metadataObjectTypes = [.qr]

        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)
        view.previewLayer = previewLayer

        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }

        return view
    }

    func updateUIView(_ uiView: CameraPreviewView, context: Context) {}

    class CameraPreviewView: UIView {
        var previewLayer: AVCaptureVideoPreviewLayer?

        override func layoutSubviews() {
            super.layoutSubviews()
            previewLayer?.frame = bounds
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onCodeScanned: onCodeScanned)
    }

    class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        let onCodeScanned: (String) -> Void
        var previewLayer: AVCaptureVideoPreviewLayer?
        private var hasScanned = false

        init(onCodeScanned: @escaping (String) -> Void) {
            self.onCodeScanned = onCodeScanned
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput,
                            didOutput metadataObjects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard !hasScanned,
                  let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  object.type == .qr,
                  let value = object.stringValue,
                  value.hasPrefix("easy://pair") else { return }

            hasScanned = true
            onCodeScanned(value)
        }
    }
}
