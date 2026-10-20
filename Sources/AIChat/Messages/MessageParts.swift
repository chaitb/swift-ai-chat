import Foundation

/// A text part of a message.
public struct TextPart: Hashable, Sendable {
    public enum State: String, Hashable, Sendable {
        case streaming
        case done
    }

    public var text: String
    public var state: State?
    public var providerMetadata: JSONValue?
    /// References that support this text, with the ranges they cover (AI SDK v7).
    public var citations: [TextCitation]?
    public var extra: [String: JSONValue]

    public init(
        text: String,
        state: State? = nil,
        providerMetadata: JSONValue? = nil,
        citations: [TextCitation]? = nil,
        extra: [String: JSONValue] = [:]
    ) {
        self.text = text
        self.state = state
        self.providerMetadata = providerMetadata
        self.citations = citations
        self.extra = extra
    }
}

/// A reference supporting part of a text part.
public struct TextCitation: Hashable, Sendable {
    public enum Source: Hashable, Sendable {
        case url(SourceURLPart)
        case document(SourceDocumentPart)
    }

    public var source: Source
    /// The start of the supported range in the text, in UTF-16 code units.
    public var startIndex: Int?
    /// The end of the supported range in the text, in UTF-16 code units.
    public var endIndex: Int?
    /// The quoted text from the source.
    public var citedText: String?

    public init(source: Source, startIndex: Int? = nil, endIndex: Int? = nil, citedText: String? = nil) {
        self.source = source
        self.startIndex = startIndex
        self.endIndex = endIndex
        self.citedText = citedText
    }

    init?(jsonValue: JSONValue) {
        guard let source = jsonValue["source"], let id = source["id"]?.stringValue else { return nil }
        switch source["sourceType"]?.stringValue {
        case "url":
            guard let url = source["url"]?.stringValue else { return nil }
            self.source = .url(SourceURLPart(sourceId: id, url: url, title: source["title"]?.stringValue, providerMetadata: source["providerMetadata"]))
        case "document":
            guard let mediaType = source["mediaType"]?.stringValue else { return nil }
            self.source = .document(SourceDocumentPart(
                sourceId: id,
                mediaType: mediaType,
                title: source["title"]?.stringValue ?? "",
                filename: source["filename"]?.stringValue,
                providerMetadata: source["providerMetadata"]
            ))
        default:
            return nil
        }
        startIndex = jsonValue["startIndex"]?.intValue
        endIndex = jsonValue["endIndex"]?.intValue
        citedText = jsonValue["citedText"]?.stringValue
    }

    var jsonValue: JSONValue {
        var source = ObjectWriter()
        source.set("type", "source")
        switch self.source {
        case .url(let url):
            source.set("sourceType", "url")
            source.set("id", url.sourceId)
            source.set("url", url.url)
            source.set("title", url.title)
            source.set("providerMetadata", url.providerMetadata)
        case .document(let document):
            source.set("sourceType", "document")
            source.set("id", document.sourceId)
            source.set("mediaType", document.mediaType)
            source.set("title", document.title)
            source.set("filename", document.filename)
            source.set("providerMetadata", document.providerMetadata)
        }
        var writer = ObjectWriter()
        writer.set("source", source.object)
        writer.set("startIndex", startIndex)
        writer.set("endIndex", endIndex)
        writer.set("citedText", citedText)
        return .object(writer.object)
    }

    static func list(from value: JSONValue?) -> [TextCitation]? {
        guard let array = value?.arrayValue else { return nil }
        return array.compactMap(TextCitation.init(jsonValue:))
    }
}

/// A reasoning part of a message: the model's visible thinking or its summary.
public struct ReasoningPart: Hashable, Sendable {
    public var text: String
    public var state: TextPart.State?
    public var providerMetadata: JSONValue?
    /// The id of the reasoning part, sent by AI SDK v7 servers.
    public var id: String?
    public var extra: [String: JSONValue]

    public init(
        text: String,
        state: TextPart.State? = nil,
        providerMetadata: JSONValue? = nil,
        id: String? = nil,
        extra: [String: JSONValue] = [:]
    ) {
        self.text = text
        self.state = state
        self.providerMetadata = providerMetadata
        self.id = id
        self.extra = extra
    }
}

/// A web page the model cited.
public struct SourceURLPart: Hashable, Sendable {
    public var sourceId: String
    public var url: String
    public var title: String?
    public var providerMetadata: JSONValue?
    public var extra: [String: JSONValue]

    public init(sourceId: String, url: String, title: String? = nil, providerMetadata: JSONValue? = nil, extra: [String: JSONValue] = [:]) {
        self.sourceId = sourceId
        self.url = url
        self.title = title
        self.providerMetadata = providerMetadata
        self.extra = extra
    }
}

/// A document the model cited.
public struct SourceDocumentPart: Hashable, Sendable {
    public var sourceId: String
    public var mediaType: String
    public var title: String
    public var filename: String?
    public var providerMetadata: JSONValue?
    public var extra: [String: JSONValue]

    public init(
        sourceId: String,
        mediaType: String,
        title: String,
        filename: String? = nil,
        providerMetadata: JSONValue? = nil,
        extra: [String: JSONValue] = [:]
    ) {
        self.sourceId = sourceId
        self.mediaType = mediaType
        self.title = title
        self.filename = filename
        self.providerMetadata = providerMetadata
        self.extra = extra
    }
}

/// A file attached by the user or produced by the model.
///
/// `url` is either a hosted URL, a path your backend understands, or a `data:` URL.
public struct FilePart: Hashable, Sendable {
    public var mediaType: String
    public var url: String
    public var filename: String?
    public var providerMetadata: JSONValue?
    /// Provider file ids for files uploaded through a provider's files API (AI SDK v7).
    public var providerReference: JSONValue?
    public var extra: [String: JSONValue]

    public init(
        mediaType: String,
        url: String,
        filename: String? = nil,
        providerMetadata: JSONValue? = nil,
        providerReference: JSONValue? = nil,
        extra: [String: JSONValue] = [:]
    ) {
        self.mediaType = mediaType
        self.url = url
        self.filename = filename
        self.providerMetadata = providerMetadata
        self.providerReference = providerReference
        self.extra = extra
    }

    /// A file part that embeds `data` as a base64 `data:` URL.
    public init(data: Data, mediaType: String, filename: String? = nil) {
        self.init(mediaType: mediaType, url: "data:\(mediaType);base64,\(data.base64EncodedString())", filename: filename)
    }

    public var isImage: Bool { mediaType.lowercased().hasPrefix("image") }

    /// The decoded bytes when `url` is a base64 `data:` URL.
    public var inlineData: Data? {
        DataURL(url)?.data
    }
}

/// A custom data part, sent as `data-<name>`.
public struct DataPart: Hashable, Sendable {
    /// The name after the `data-` prefix.
    public var name: String
    /// Parts with an id are replaced in place when the server sends the same id again.
    public var id: String?
    public var data: JSONValue
    public var extra: [String: JSONValue]

    public init(name: String, data: JSONValue, id: String? = nil, extra: [String: JSONValue] = [:]) {
        self.name = name
        self.data = data
        self.id = id
        self.extra = extra
    }

    public var type: String { "data-\(name)" }

    /// Decodes the payload into your own type.
    public func decode<T: Decodable>(_ type: T.Type = T.self, using decoder: JSONDecoder = JSONDecoder()) throws -> T {
        try data.decode(T.self, using: decoder)
    }
}

/// Provider-specific content the AI SDK passes through as `custom` (AI SDK v7).
public struct CustomPart: Hashable, Sendable {
    /// The kind, in the form `provider.type`.
    public var kind: String
    public var providerMetadata: JSONValue?
    public var extra: [String: JSONValue]

    public init(kind: String, providerMetadata: JSONValue? = nil, extra: [String: JSONValue] = [:]) {
        self.kind = kind
        self.providerMetadata = providerMetadata
        self.extra = extra
    }
}

/// A part of a type this version of the package doesn't model. Its JSON is kept as is.
public struct UnknownPart: Hashable, Sendable {
    public var type: String
    public var object: [String: JSONValue]

    public init(type: String, object: [String: JSONValue]) {
        self.type = type
        self.object = object
    }
}

/// Parses `data:` URLs.
struct DataURL {
    let mediaType: String
    let data: Data

    init?(_ string: String) {
        guard string.hasPrefix("data:"), let comma = string.firstIndex(of: ",") else { return nil }
        let header = string[string.index(string.startIndex, offsetBy: 5)..<comma]
        let payload = String(string[string.index(after: comma)...])
        let attributes = header.split(separator: ";").map(String.init)
        guard attributes.contains("base64") else {
            guard let decoded = payload.removingPercentEncoding else { return nil }
            mediaType = attributes.first ?? "text/plain"
            data = Data(decoded.utf8)
            return
        }
        guard let decoded = Data(base64Encoded: payload, options: .ignoreUnknownCharacters) else { return nil }
        mediaType = attributes.first.flatMap { $0.isEmpty || $0 == "base64" ? nil : $0 } ?? "application/octet-stream"
        data = decoded
    }
}
