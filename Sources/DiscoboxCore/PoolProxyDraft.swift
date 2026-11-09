import Foundation

public struct PoolProxyDraft: Equatable, Sendable {
    public var defaults = true
    public var mode = "direct"
    public var http = ""
    public var https = ""
    public var noProxy = ""
    public var caPEM = ""
    public var httpCredentials = ""
    public var httpsCredentials = ""
    public var clearHTTP = false
    public var clearHTTPS = false
    public init(proxy: JSONValue) {
        defaults = proxy == .null
        mode = proxy["mode"].string.isEmpty ? "direct" : proxy["mode"].string
        http = proxy["http"].string; https = proxy["https"].string
        noProxy = proxy["noProxy"].string; caPEM = proxy["caPem"].string
    }
    public func payload() throws -> JSONValue {
        if defaults { return .null }
        guard ["direct", "explicit", "inherit"].contains(mode) else { throw DiscoboxError("Choose an outbound mode.") }
        var fields: [String: JSONValue] = ["mode": .string(mode)]
        if mode == "explicit" {
            fields["http"] = .string(try proxyURL(http, credentials: httpCredentials, clear: clearHTTP))
            fields["https"] = .string(try proxyURL(https, credentials: httpsCredentials, clear: clearHTTPS))
            fields["noProxy"] = .string(noProxy)
            if clearHTTP { fields["clearHttpCredentials"] = .bool(true) }
            if clearHTTPS { fields["clearHttpsCredentials"] = .bool(true) }
        }
        fields["caPem"] = .string(caPEM)
        return .object(fields)
    }
    private func proxyURL(_ text: String, credentials: String, clear: Bool) throws -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            guard credentials.isEmpty else { throw DiscoboxError("Set a proxy URL before adding credentials.") }; return ""
        }
        guard var url = URLComponents(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw DiscoboxError("Use an HTTP or HTTPS proxy URL. Enter authentication in its separate secure field.")
        }
        if !credentials.isEmpty {
            guard !clear, let colon = credentials.firstIndex(of: ":") else { throw DiscoboxError("Enter proxy authentication as username:password and turn off Clear saved credentials.") }
            url.user = String(credentials[..<colon]); url.password = String(credentials[credentials.index(after: colon)...])
        }
        guard let value = url.string else { throw DiscoboxError("Invalid proxy URL.") }; return value
    }
}
