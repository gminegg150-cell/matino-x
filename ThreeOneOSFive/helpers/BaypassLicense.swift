import SwiftUI
import Foundation

/// BaypassX activation gate for MATINO X.
///
/// License keys are issued from the BaypassX dashboard (Firebase project
/// `baypass-x-dbabb`, Firestore collection `licenses`) and are validated here
/// through the Firestore REST API. Only documents whose `status` is `Active`
/// unlock the app.
final class BaypassLicense: ObservableObject {
    static let shared = BaypassLicense()

    @Published private(set) var isActivated: Bool
    @Published private(set) var isChecking = false
    @Published private(set) var statusMessage: String?

    private static let projectID = "baypass-x-dbabb"
    private static let apiKey = "AIzaSyDDk-5RZaPuOtCd86aFhgXpMUNGaTtx5EQ"
    private static let collectionID = "licenses"
    private static let storedKeyDefaultsKey = "baypassx.license.key"

    private init() {
        isActivated = UserDefaults.standard.string(forKey: Self.storedKeyDefaultsKey) != nil
    }

    var storedKey: String? {
        UserDefaults.standard.string(forKey: Self.storedKeyDefaultsKey)
    }

    // MARK: - Public API

    func activate(rawKey: String) {
        let trimmed = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            statusMessage = "Enter your license key."
            return
        }
        guard !isChecking else { return }

        isChecking = true
        statusMessage = nil
        validate(key: trimmed) { [weak self] outcome in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isChecking = false
                switch outcome {
                case .accepted:
                    UserDefaults.standard.set(trimmed, forKey: Self.storedKeyDefaultsKey)
                    self.isActivated = true
                    self.statusMessage = nil
                case .rejected(let message), .unavailable(let message):
                    self.statusMessage = message
                }
            }
        }
    }

    /// Silent re-check of the stored key. Only a definitive rejection locks
    /// the app; a network failure keeps the current session unlocked so the
    /// app stays usable offline.
    func revalidateStoredKey() {
        guard let key = storedKey else { return }
        validate(key: key) { [weak self] outcome in
            DispatchQueue.main.async {
                guard let self else { return }
                if case .rejected(let message) = outcome {
                    UserDefaults.standard.removeObject(forKey: Self.storedKeyDefaultsKey)
                    self.isActivated = false
                    self.statusMessage = message
                }
            }
        }
    }

    func deactivate() {
        UserDefaults.standard.removeObject(forKey: Self.storedKeyDefaultsKey)
        isActivated = false
        statusMessage = nil
    }

    // MARK: - Firestore REST validation

    private enum Outcome {
        case accepted
        /// The server answered and the key is not usable.
        case rejected(String)
        /// Network or service problem — the current state should be kept.
        case unavailable(String)
    }

    private func validate(key: String, completion: @escaping (Outcome) -> Void) {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "firestore.googleapis.com"
        components.path = "/v1/projects/\(Self.projectID)/databases/(default)/documents:runQuery"
        components.queryItems = [URLQueryItem(name: "key", value: Self.apiKey)]
        guard let url = components.url else {
            completion(.unavailable("License service URL is invalid."))
            return
        }

        let query: [String: Any] = [
            "structuredQuery": [
                "from": [["collectionId": Self.collectionID]],
                "where": [
                    "fieldFilter": [
                        "field": ["fieldPath": "key"],
                        "op": "EQUAL",
                        "value": ["stringValue": key]
                    ]
                ],
                "limit": 1
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        guard let body = try? JSONSerialization.data(withJSONObject: query) else {
            completion(.unavailable("License request could not be built."))
            return
        }
        request.httpBody = body

        URLSession.shared.dataTask(with: request) { data, response, error in
            if error != nil {
                completion(.unavailable("Could not reach the license server. Check your connection."))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.unavailable("License server returned an unexpected response."))
                return
            }
            guard let data, !data.isEmpty else {
                completion(.unavailable("License server returned an empty response."))
                return
            }
            guard http.statusCode == 200 else {
                if http.statusCode == 401 || http.statusCode == 403 {
                    completion(.rejected("License service denied access. Check Firestore security rules."))
                } else {
                    completion(.rejected(Self.serverMessage(from: data) ?? "License check failed (HTTP \(http.statusCode))."))
                }
                return
            }
            completion(Self.evaluate(data: data))
        }.resume()
    }

    private static func evaluate(data: Data) -> Outcome {
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return .unavailable("License response could not be read.")
        }
        for entry in payload {
            guard let document = entry["document"] as? [String: Any],
                  let fields = document["fields"] as? [String: Any] else { continue }
            let status = (fields["status"] as? [String: Any])?["stringValue"] as? String ?? "Active"
            if status.lowercased() == "active" {
                return .accepted
            }
            return .rejected("This license is \(status.lowercased()).")
        }
        return .rejected("Invalid license key.")
    }

    private static func serverMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any] else { return nil }
        return error["message"] as? String
    }
}

// MARK: - Activation screen

struct BaypassActivationView: View {
    @ObservedObject private var license = BaypassLicense.shared
    @State private var key = ""
    @FocusState private var keyFocused: Bool

    var body: some View {
        ZStack {
            AppTheme.pageBackground
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 18) {
                    AppLogo(size: 76)

                    Text("MATINO X")
                        .font(.system(size: 30, weight: .bold, design: .rounded))

                    Text("Enter your license key to unlock the app.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    TextField("baypassx-XXXX-XXXX-XXXX", text: $key)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .focused($keyFocused)
                        .onSubmit(activate)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 46)
                        .background(
                            Color(uiColor: .secondarySystemFill),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )

                    Button(action: activate) {
                        ZStack {
                            if license.isChecking {
                                ProgressView()
                                    .tint(AppTheme.accent)
                            } else {
                                Text("Activate")
                                    .fontWeight(.semibold)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 46)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.accent)
                    .disabled(license.isChecking || normalizedKey.isEmpty)

                    if let message = license.statusMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    Text("No key? Contact the seller who provided this build.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
                .frame(maxWidth: 440)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 400)
            }
        }
        .onAppear {
            keyFocused = true
        }
    }

    private var normalizedKey: String {
        key.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func activate() {
        license.activate(rawKey: key)
    }
}
