import Foundation

enum HTTPError: LocalizedError {
    case notConfigured(String)
    case badURL
    case status(Int, String?)
    case decoding(String)
    case emptyBody

    var errorDescription: String? {
        switch self {
        case .notConfigured(let what): return "\(what) が設定されていません。"
        case .badURL: return "URL が不正です。"
        case .status(let code, let body):
            if let body, !body.isEmpty {
                return "HTTP \(code): \(body.prefix(200))"
            }
            return "HTTP \(code)"
        case .decoding(let detail): return "レスポンスを解釈できませんでした: \(detail)"
        case .emptyBody: return "レスポンスが空でした。"
        }
    }
}

enum JSONCoders {
    /// 秒の小数あり（`...15:33:29.609314+09:00`）と小数なし（`...15:39:48+09:00`）の両方を読む。
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]

        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = withFraction.date(from: raw) { return date }
            if let date = plain.date(from: raw) { return date }
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "日付を解釈できません: \(raw)")
            )
        }
        return decoder
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

/// multipart/form-data のボディを組み立てる。
struct MultipartBody {
    let boundary = "AbVoice-\(UUID().uuidString)"
    private var data = Data()

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func append(name: String, value: String) {
        data.append("--\(boundary)\r\n")
        data.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        data.append(value)
        data.append("\r\n")
    }

    mutating func append(name: String, fileName: String, mimeType: String, fileData: Data) {
        data.append("--\(boundary)\r\n")
        data.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(fileName)\"\r\n")
        data.append("Content-Type: \(mimeType)\r\n\r\n")
        data.append(fileData)
        data.append("\r\n")
    }

    func finalized() -> Data {
        var out = data
        out.append("--\(boundary)--\r\n")
        return out
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}

extension URLResponse {
    var httpStatusCode: Int { (self as? HTTPURLResponse)?.statusCode ?? 0 }
}
