import Foundation

/// A file attachment in the form a model provider accepts.
public enum ResolvedFile: Sendable, Hashable {
    /// The bytes, sent inline as base64.
    case data(Data, mediaType: String)
    /// A public URL the provider fetches itself.
    case url(URL, mediaType: String)
    /// Plain text, for text documents.
    case text(String, mediaType: String)
    /// A file already uploaded to the provider's files API.
    case providerFileID(String, mediaType: String)

    public var mediaType: String {
        switch self {
        case .data(_, let mediaType), .url(_, let mediaType), .text(_, let mediaType), .providerFileID(_, let mediaType): mediaType
        }
    }
}

/// Turns a ``FilePart`` into something a provider accepts. Return `nil` to leave the file out.
public typealias FileResolver = @Sendable (FilePart) async throws -> ResolvedFile?

/// Built-in ways to resolve file parts for direct provider transports.
public enum FileResolution {
    /// `data:` URLs become inline bytes and `http(s)` URLs are passed to the provider.
    /// Anything else, such as a path your own backend serves, fails with a clear error.
    @Sendable public static func inline(_ file: FilePart) throws -> ResolvedFile? {
        if let dataURL = DataURL(file.url) {
            return .data(dataURL.data, mediaType: file.mediaType.isEmpty ? dataURL.mediaType : file.mediaType)
        }
        if let url = URL(string: file.url), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            return .url(url, mediaType: file.mediaType)
        }
        if let url = URL(string: file.url), url.isFileURL {
            do {
                return .data(try Data(contentsOf: url), mediaType: file.mediaType)
            } catch {
                throw ChatError(kind: .configuration, message: "The attachment \(file.filename ?? url.lastPathComponent) couldn't be read.", underlying: String(describing: error))
            }
        }
        throw ChatError(
            kind: .configuration,
            message: "The attachment URL \(file.url) can't be sent to the provider. Use a data: or https URL, or set a file resolver.",
            code: "unsupported_file_url"
        )
    }

    /// Downloads every non-`data:` file and sends its bytes inline. Relative URLs are
    /// resolved against `baseURL`, and `headers` (such as a session cookie) are sent
    /// with each download.
    public static func downloading(
        baseURL: URL? = nil,
        headers: [String: String] = [:],
        httpClient: any HTTPStreamingClient = URLSessionStreamingClient(),
        maxBytes: Int = 32 * 1_024 * 1_024
    ) -> FileResolver {
        { file in
            if let dataURL = DataURL(file.url) {
                return .data(dataURL.data, mediaType: file.mediaType.isEmpty ? dataURL.mediaType : file.mediaType)
            }
            guard let url = URL(string: file.url, relativeTo: baseURL)?.absoluteURL else {
                throw ChatError(kind: .configuration, message: "The attachment URL \(file.url) isn't valid.", code: "invalid_file_url")
            }
            var request = URLRequest(url: url, timeoutInterval: 120)
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            let response: HTTPStreamResponse
            do {
                response = try await httpClient.send(request)
            } catch {
                throw ChatError.from(error, operation: "file.download")
            }
            guard response.isSuccess else { throw await response.failure(operation: "file.download") }
            let data = try await response.collectBody(limit: maxBytes)
            let mediaType = file.mediaType.isEmpty ? (response.header("content-type") ?? "application/octet-stream") : file.mediaType
            return .data(data, mediaType: mediaType)
        }
    }
}
