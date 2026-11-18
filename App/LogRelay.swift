import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Optional plain-text log export to an explicitly configured HTTP(S) endpoint.
/// No endpoint is configured by default, so unconfigured exports are skipped.
final class LogRelay {
    static var endpoint: URL? {
        guard let value = UserDefaults.standard.string(forKey: "logRelayURL"),
              let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }

    func post(_ text: String, completion: @escaping (Result<Int, Error>) -> Void) {
        guard let endpoint = Self.endpoint else {
            completion(.success(0)) // Disabled, no outgoing request.
            return
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(text.utf8)

        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200...299).contains(code) {
                completion(.success(code))
            } else {
                let failure = NSError(domain: "LogRelay", code: code,
                                      userInfo: [NSLocalizedDescriptionKey: "HTTP \(code)"])
                completion(.failure(failure))
            }
        }.resume()
    }
}
