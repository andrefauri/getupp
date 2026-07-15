//
//  CameraView.swift
//  Getupp
//
//  Camera capture screen: live preview → shutter → API call → result.
//  Uses AVFoundation for live capture (no photo library — anti-cheat requirement).
//

import AVFoundation
import SwiftUI
import UIKit

// MARK: - Verification state

enum VerificationState {
    case idle                       // waiting to take photo
    case previewing(UIImage)        // photo taken, ready to send
    case loading                    // API call in progress
    case pass(VerificationResult)   // verified — out of bed
    case fail(VerificationResult)   // not verified — still in bed
    case error(String)              // network/API/parse failure (distinct from "in bed")
}

// MARK: - Top-level SwiftUI view

struct CameraView: View {

    // Injected from the environment so we can call markVerified() on pass.
    @EnvironmentObject var shieldManager: ShieldManager
    @Environment(\.presentationMode) var presentationMode

    @State private var state: VerificationState = .idle

    private let service = VerificationService()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch state {
            case .idle:
                idleView

            case .previewing(let image):
                previewView(image: image)

            case .loading:
                loadingView

            case .pass(let result):
                passView(result: result)

            case .fail(let result):
                failView(result: result)

            case .error(let message):
                errorView(message: message)
            }
        }
        .navigationTitle("Verify")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    // MARK: - Idle: live camera preview + shutter

    private var idleView: some View {
        CameraPreview(onCapture: { image in
            state = .previewing(image)
        })
        .ignoresSafeArea()
    }

    // MARK: - Preview: confirm before sending

    private func previewView(image: UIImage) -> some View {
        VStack(spacing: 24) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .padding()

            HStack(spacing: 24) {
                Button("Retake") {
                    state = .idle
                }
                .buttonStyle(.bordered)
                .tint(.white)

                Button("Send to Claude") {
                    Task { await runVerification(image: image) }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .foregroundColor(.white)
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(2)
                .tint(.white)
            Text("Asking Claude…")
                .foregroundColor(.white)
        }
    }

    // MARK: - Pass

    private func passView(result: VerificationResult) -> some View {
        VStack(spacing: 20) {
            Text("YOU'RE UP.")
                .font(.system(size: 52, weight: .black))
                .foregroundColor(.green)

            Text("Apps unblocked.")
                .font(.title2.bold())
                .foregroundColor(.white)

            Text(String(format: "Confidence: %.0f%%", result.confidence * 100))
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.7))

            Text(result.reason)
                .font(.caption)
                .foregroundColor(.white.opacity(0.5))
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button("Done") {
                // Navigate back to the main screen.
                presentationMode.wrappedValue.dismiss()
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .padding(.top, 8)
        }
        .padding()
    }

    // MARK: - Fail

    private func failView(result: VerificationResult) -> some View {
        VStack(spacing: 20) {
            Text("NOPE.")
                .font(.system(size: 64, weight: .black))
                .foregroundColor(.red)

            Text("Still looks like you're in bed.")
                .font(.title3.bold())
                .foregroundColor(.white)

            // Show the model's reason — this becomes retry coaching in v2.
            Text(result.reason)
                .font(.body)
                .foregroundColor(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Text(String(format: "Confidence: %.0f%%", result.confidence * 100))
                .font(.caption)
                .foregroundColor(.white.opacity(0.5))

            Button("Try Again") {
                state = .idle
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .padding(.top, 8)
        }
        .padding()
    }

    // MARK: - Error (network/API/parse — distinct from "you're in bed")

    private func errorView(message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundColor(.yellow)

            Text("Couldn't verify")
                .font(.title.bold())
                .foregroundColor(.white)

            // Clearly different from "you're in bed" — the system failed, not the user.
            Text(message)
                .font(.callout)
                .foregroundColor(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Text("Apps stay blocked (fail-closed).")
                .font(.caption)
                .foregroundColor(.white.opacity(0.5))

            Button("Try Again") {
                state = .idle
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    // MARK: - Verification call

    private func runVerification(image: UIImage) async {
        state = .loading
        do {
            let result = try await service.verify(image: image)
            if result.outOfBed {
                // PASS: write lastVerifiedDate and clear the shield.
                shieldManager.markVerified()
                state = .pass(result)
            } else {
                // FAIL: shield stays, do not touch lastVerifiedDate.
                state = .fail(result)
            }
        } catch let e as VerificationError {
            // System error — fail-closed, shield stays.
            state = .error(errorMessage(for: e))
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    private func errorMessage(for error: VerificationError) -> String {
        switch error {
        case .missingAPIKey:
            return "API key not set. Open Secrets.plist and paste your Anthropic key."
        case .missingPrompt:
            return "Prompt file not found. Make sure production-v1.txt is in the Getupp target."
        case .imageEncodingFailed:
            return "Failed to encode the photo."
        case .networkError(let e):
            return "Network error: \(e.localizedDescription)"
        case .apiError(let code, let body):
            return "API error \(code): \(body)"
        case .parseError(let raw):
            return "Unexpected response from Claude: \(raw)"
        }
    }
}

// MARK: - UIViewControllerRepresentable wrapper

/// Bridges AVFoundation (UIKit) into SwiftUI.
/// SwiftUI can't use AVCaptureSession directly — it must go through UIKit.
struct CameraPreview: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void

    func makeUIViewController(context: Context) -> CameraViewController {
        let vc = CameraViewController()
        vc.onCapture = onCapture
        return vc
    }

    func updateUIViewController(_ uiViewController: CameraViewController, context: Context) {}
}

// MARK: - CameraViewController

/// Manages AVCaptureSession, live preview, and photo capture.
final class CameraViewController: UIViewController {

    var onCapture: ((UIImage) -> Void)?

    // AVFoundation pipeline
    private let session     = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private var previewLayer: AVCaptureVideoPreviewLayer!

    // Shutter button (lives in UIKit so it sits on top of the preview layer)
    private let shutterButton = UIButton(type: .system)

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        checkPermissionAndSetup()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds

        // Keep shutter button at bottom-centre regardless of screen size.
        let size: CGFloat = 72
        shutterButton.frame = CGRect(
            x: (view.bounds.width - size) / 2,
            y: view.bounds.height - size - 48,
            width: size,
            height: size
        )
        shutterButton.layer.cornerRadius = size / 2
    }

    // MARK: - Permission

    private func checkPermissionAndSetup() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setupSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted { self?.setupSession() }
                    else       { self?.showDeniedMessage() }
                }
            }
        default:
            showDeniedMessage()
        }
    }

    private func showDeniedMessage() {
        let label = UILabel()
        label.text = "Camera access denied.\nGo to Settings → GETUPP → Camera."
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
        ])
    }

    // MARK: - AVCaptureSession setup

    private func setupSession() {
        session.beginConfiguration()
        session.sessionPreset = .photo

        // Front camera — selfie-style proof photo.
        guard
            let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
            let input  = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(input)
        else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)

        guard session.canAddOutput(photoOutput) else {
            session.commitConfiguration()
            return
        }
        session.addOutput(photoOutput)
        session.commitConfiguration()

        // Preview layer fills the view.
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.insertSublayer(previewLayer, at: 0)

        // Start the session on a background thread (required by Apple).
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.startRunning()
        }

        setupShutterButton()
    }

    // MARK: - Shutter button

    private func setupShutterButton() {
        shutterButton.backgroundColor = .white
        shutterButton.layer.borderColor = UIColor.gray.cgColor
        shutterButton.layer.borderWidth = 3
        shutterButton.addTarget(self, action: #selector(capturePhoto), for: .touchUpInside)
        view.addSubview(shutterButton)
    }

    @objc private func capturePhoto() {
        let settings = AVCapturePhotoSettings()
        photoOutput.capturePhoto(with: settings, delegate: self)
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension CameraViewController: AVCapturePhotoCaptureDelegate {

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        guard
            error == nil,
            let data  = photo.fileDataRepresentation(),
            let image = UIImage(data: data)
        else { return }

        // Stop the session immediately — we don't need it anymore.
        session.stopRunning()

        DispatchQueue.main.async { [weak self] in
            self?.onCapture?(image)
        }
    }
}
