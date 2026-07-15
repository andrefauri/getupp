//
//  VerificationService.swift
//  Getupp
//
//  Sends a captured photo to the Anthropic API and returns a pass/fail verdict.
//
//  ⚠️  POC ONLY: The API key lives in Secrets.plist on-device.
//  Before ANY distribution (even TestFlight), this call must move behind
//  a Supabase Edge Function proxy. Never ship a client-side API key.
//

import Foundation
import UIKit

// MARK: - Result types

struct VerificationResult {
    let outOfBed: Bool
    let confidence: Double
    let reason: String
}

enum VerificationError: Error {
    case missingAPIKey
    case missingPrompt
    case imageEncodingFailed
    case networkError(Error)
    case apiError(Int, String)   // HTTP status + body excerpt
    case parseError(String)      // raw response excerpt
}

// MARK: - Service

struct VerificationService {

    // MARK: - Public API

    /// Prepares the image and calls the Anthropic Messages API.
    /// Always returns: either a VerificationResult or a VerificationError.
    /// Never throws in a way that reaches the caller silently — errors are explicit.
    func verify(image: UIImage) async throws -> VerificationResult {
        let apiKey  = try loadAPIKey()
        let prompt  = try loadPrompt()
        let b64     = try prepareImage(image)

        let raw = try await callAPI(apiKey: apiKey, prompt: prompt, imageB64: b64)
        return try parseResponse(raw)
    }

    // MARK: - Image preparation

    /// Bakes EXIF orientation into pixels, resizes to max 1024px, compresses to JPEG ~80%.
    /// Matches the Python pipeline: ImageOps.exif_transpose() → resize → JPEG quality=80.
    private func prepareImage(_ image: UIImage) throws -> String {
        // Step 1: normalise orientation.
        // UIImage from AVFoundation often has .right orientation (landscape data in portrait frame).
        // Drawing into a new context bakes the transform into the pixels so the API sees the image
        // the right way up regardless of EXIF metadata.
        let normalised: UIImage
        if image.imageOrientation == .up {
            normalised = image
        } else {
            UIGraphicsBeginImageContextWithOptions(image.size, false, image.scale)
            image.draw(in: CGRect(origin: .zero, size: image.size))
            normalised = UIGraphicsGetImageFromCurrentImageContext() ?? image
            UIGraphicsEndImageContext()
        }

        // Step 2: resize so the longest side is at most 1024px.
        let maxSide: CGFloat = 1024
        let size = normalised.size
        let resized: UIImage
        if max(size.width, size.height) > maxSide {
            let ratio   = maxSide / max(size.width, size.height)
            let newSize = CGSize(width: size.width * ratio, height: size.height * ratio)
            UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
            normalised.draw(in: CGRect(origin: .zero, size: newSize))
            resized = UIGraphicsGetImageFromCurrentImageContext() ?? normalised
            UIGraphicsEndImageContext()
        } else {
            resized = normalised
        }

        // Step 3: encode as JPEG quality 0.8, then base64.
        guard let jpegData = resized.jpegData(compressionQuality: 0.8) else {
            throw VerificationError.imageEncodingFailed
        }

        // The image data is used here and then released. It is never stored.
        return jpegData.base64EncodedString()
    }

    // MARK: - API call

    /// POSTs to the Anthropic Messages API and returns the raw text response.
    private func callAPI(apiKey: String, prompt: String, imageB64: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey,        forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01",  forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.timeoutInterval = 30

        // Build the message body. Image content comes before the text prompt,
        // matching the order in classify.py.
        let body: [String: Any] = [
            "model": "claude-haiku-4-5",
            "max_tokens": 256,
            "messages": [[
                "role": "user",
                "content": [
                    [
                        "type": "image",
                        "source": [
                            "type": "base64",
                            "media_type": "image/jpeg",
                            "data": imageB64
                        ]
                    ],
                    [
                        "type": "text",
                        "text": prompt
                    ]
                ]
            ]]
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw VerificationError.networkError(error)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw VerificationError.networkError(error)
        }

        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw VerificationError.apiError(statusCode, String(body.prefix(200)))
        }

        // Extract the text from the response JSON: content[0].text
        guard
            let json    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let content = json["content"] as? [[String: Any]],
            let first   = content.first,
            let text    = first["text"] as? String
        else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw VerificationError.parseError("unexpected response shape: \(raw.prefix(200))")
        }

        return text
    }

    // MARK: - Response parsing

    /// Strips markdown fences, parses JSON, validates required keys.
    /// Any parsing failure is a VerificationError — never a crash.
    private func parseResponse(_ raw: String) throws -> VerificationResult {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip ```json ... ``` or ``` ... ``` fences the model might add despite instructions.
        if cleaned.hasPrefix("```") {
            cleaned = cleaned
                .replacingOccurrences(of: #"^```(?:json)?\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s*```$"#,         with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard
            let data    = cleaned.data(using: .utf8),
            let json    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let outOfBed    = json["out_of_bed"]  as? Bool,
            let confidence  = json["confidence"]  as? Double,
            let reason      = json["reason"]      as? String
        else {
            throw VerificationError.parseError(String(raw.prefix(200)))
        }

        return VerificationResult(
            outOfBed:   outOfBed,
            confidence: confidence,
            reason:     reason
        )
    }

    // MARK: - Resource loading

    private func loadAPIKey() throws -> String {
        guard
            let url  = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
            let dict = NSDictionary(contentsOf: url),
            let key  = dict["ANTHROPIC_API_KEY"] as? String,
            !key.isEmpty,
            key != "PASTE_YOUR_KEY_HERE"
        else {
            throw VerificationError.missingAPIKey
        }
        return key
    }

    private func loadPrompt() throws -> String {
        guard
            let url  = Bundle.main.url(forResource: "production-v1", withExtension: "txt"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            throw VerificationError.missingPrompt
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
