import Foundation

/// 夸克网盘文件模型
public struct QuarkFile: Identifiable, Sendable, Codable {
    public let id: String           // fid
    public let fileName: String
    public let fileSize: Int64
    public let isFile: Bool         // "file" field: true=file, false=dir
    public let updatedAt: Int64     // unix timestamp ms
    public let parentFid: String

    public var isDir: Bool { !isFile }

    public var fileExtension: String {
        (fileName as NSString).pathExtension.lowercased()
    }

    public var isAudioFile: Bool {
        guard isFile else { return false }
        let exts: Set<String> = ["flac","ape","wav","aiff","aif","dsf","dff",
                                  "alac","m4a","mp3","ogg","opus","wv","mpc","tta","mp4","aac","caf","dts"]
        return exts.contains(fileExtension)
    }

    enum CodingKeys: String, CodingKey {
        case id = "fid"
        case fileName = "file_name"
        case fileSize = "size"
        case isFile = "file"
        case updatedAt = "updated_at"
        case parentFid = "pdir_fid"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.fileName = try c.decodeIfPresent(String.self, forKey: .fileName) ?? ""
        self.fileSize = try c.decodeIfPresent(Int64.self, forKey: .fileSize) ?? 0
        self.isFile = try c.decodeIfPresent(Bool.self, forKey: .isFile) ?? true
        // updated_at can be Int64 or occasionally missing
        self.updatedAt = try c.decodeIfPresent(Int64.self, forKey: .updatedAt) ?? 0
        self.parentFid = try c.decodeIfPresent(String.self, forKey: .parentFid) ?? "0"
    }

    public init(id: String, fileName: String, fileSize: Int64 = 0,
                isDir: Bool = false, updatedAt: String = "", parentFid: String = "0") {
        self.id = id
        self.fileName = fileName
        self.fileSize = fileSize
        self.isFile = !isDir
        self.updatedAt = 0
        self.parentFid = parentFid
    }
}

/// 夸克 API 响应包装 — 兼容多种返回格式
public struct QuarkListResponse: Decodable {
    public let status: Int?
    public let code: Int?
    public let message: String?
    public let data: QuarkFileListData?
}

public struct QuarkFileListData: Decodable {
    public let list: [QuarkFile]?

    enum CodingKeys: String, CodingKey {
        case list
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.list = try c.decodeIfPresent([QuarkFile].self, forKey: .list)
    }
}

public struct QuarkDownloadData: Decodable {
    public let downloadUrl: String?

    enum CodingKeys: String, CodingKey {
        case downloadUrl = "download_url"
    }
}

/// 夸克网盘 API 客户端
public final class QuarkAPIClient: @unchecked Sendable {

    public static let baseURL = "https://drive-pc.quark.cn"
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) quark-cloud-drive/3.14.2 "
        + "Chrome/112.0.5615.165 Electron/24.1.3.8 Safari/537.36"

    private var cookies: [String: String] = [:]
    private let session: URLSession
    private let rateLimiter: RateLimiter
    private let keychain: KeychainStore

    public private(set) var isLoggedIn: Bool = false

    public init(rateLimiter: RateLimiter = RateLimiter(),
                keychain: KeychainStore = KeychainStore()) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
        self.rateLimiter = rateLimiter
        self.keychain = keychain

        if let saved = keychain.loadCookies() {
            self.cookies = saved
            self.isLoggedIn = !saved.isEmpty
        }
    }

    // MARK: - Auth

    public func setCookies(_ cookies: [String: String]) {
        self.cookies = cookies
        self.isLoggedIn = !cookies.isEmpty
        try? keychain.saveCookies(cookies)
    }

    public func logout() {
        cookies = [:]
        isLoggedIn = false
        keychain.clearCookies()
    }

    // MARK: - File Operations

    public func listFiles(parentFid: String = "0", page: Int = 1, size: Int = 100) async throws -> [QuarkFile] {
        await rateLimiter.acquireAsync()
        let url = "\(Self.baseURL)/1/clouddrive/file/sort"
            + "?pdir_fid=\(parentFid)&_page=\(page)&_size=\(size)"
            + "&_fetch_total=1&_sort=file_type:asc,updated_at:desc"
            + "&pr=ucpro&fr=pc"

        let data = try await get(url: url)

        // Try strict decode first
        if let resp = try? JSONDecoder().decode(QuarkListResponse.self, from: data),
           let list = resp.data?.list {
            return list
        }

        // Fallback: manual JSON parsing for maximum compatibility
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let preview = String(data: data.prefix(200), encoding: .utf8) ?? "(binary)"
            throw PurePlayError.ioError("Invalid JSON response: \(preview)")
        }

        // Navigate to data.list regardless of nesting
        let dataObj = json["data"] as? [String: Any]
        let listArray: [[String: Any]]
        if let arr = dataObj?["list"] as? [[String: Any]] {
            listArray = arr
        } else if let arr = json["list"] as? [[String: Any]] {
            listArray = arr
        } else {
            let code = json["code"] as? Int ?? -1
            let msg = json["message"] as? String ?? "unknown"
            throw PurePlayError.ioError("API error (code=\(code)): \(msg)")
        }

        // Parse each file item manually
        var files: [QuarkFile] = []
        for item in listArray {
            let fid = item["fid"] as? String ?? ""
            guard !fid.isEmpty else { continue }
            let fileName = item["file_name"] as? String ?? item["name"] as? String ?? ""
            let fileSize: Int64
            if let s = item["size"] as? Int64 { fileSize = s }
            else if let s = item["size"] as? Int { fileSize = Int64(s) }
            else { fileSize = 0 }
            // Determine if directory: use "file" bool, "dir" bool, or "file_type" int
            let isDir: Bool
            if let f = item["file"] as? Bool { isDir = !f }
            else if let d = item["dir"] as? Bool { isDir = d }
            else if let ft = item["file_type"] as? Int { isDir = ft == 0 }
            else { isDir = false }
            let parentFid = item["pdir_fid"] as? String ?? "0"

            files.append(QuarkFile(id: fid, fileName: fileName, fileSize: fileSize,
                                   isDir: isDir, updatedAt: "", parentFid: parentFid))
        }
        return files
    }

    public func listAudioFiles(parentFid: String = "0") async throws -> [QuarkFile] {
        let all = try await listFiles(parentFid: parentFid)
        return all.filter { $0.isAudioFile || $0.isDir }
    }

    /// 列出目录下所有文件（不过滤，包含所有类型）
    public func listAllFiles(parentFid: String = "0") async throws -> [QuarkFile] {
        try await listFiles(parentFid: parentFid)
    }

    public func getDownloadURL(fid: String) async throws -> URL {
        await rateLimiter.acquireAsync()
        let url = "\(Self.baseURL)/1/clouddrive/file/download?pr=ucpro&fr=pc"
        let body: [String: Any] = ["fids": [fid]]
        let data = try await post(url: url, jsonBody: body)

        struct DownloadResp: Decodable {
            let status: Int
            let data: [DownloadItem]?
            struct DownloadItem: Decodable {
                let download_url: String?
            }
        }
        let resp = try JSONDecoder().decode(DownloadResp.self, from: data)
        guard let urlStr = resp.data?.first?.download_url,
              let downloadURL = URL(string: urlStr) else {
            throw PurePlayError.ioError("No download URL returned")
        }
        return downloadURL
    }

    /// 下载文件头部（用于格式探测）
    public func downloadHeader(fid: String, bytes: Int = 65536) async throws -> Data {
        let downloadURL = try await getDownloadURL(fid: fid)
        var request = URLRequest(url: downloadURL)
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("https://pan.quark.cn", forHTTPHeaderField: "Referer")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("bytes=0-\(bytes - 1)", forHTTPHeaderField: "Range")

        let (data, _) = try await session.data(for: request)
        return data
    }

    /// 获取完整下载 URLRequest（供 CloudStreamSource 使用）
    public func makeDownloadRequest(fid: String, range: Range<Int64>? = nil) async throws -> URLRequest {
        let downloadURL = try await getDownloadURL(fid: fid)
        var request = URLRequest(url: downloadURL)
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("https://pan.quark.cn", forHTTPHeaderField: "Referer")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let range = range {
            request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)",
                           forHTTPHeaderField: "Range")
        }
        return request
    }

    /// Cookie 失效 / 未授权时的回调（UI 路由到重登流程）
    /// 在主线程被调用；调用前已自动清空 cookies + isLoggedIn=false
    public var onAuthExpired: (() -> Void)?

    // MARK: - HTTP Helpers

    private func get(url urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else {
            throw PurePlayError.ioError("Invalid URL: \(urlString)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyHeaders(&request)
        let (data, response) = try await session.data(for: request)
        refreshCookies(from: response)
        checkAuthStatus(response: response, data: data)
        return data
    }

    private func post(url urlString: String, jsonBody: [String: Any]) async throws -> Data {
        guard let url = URL(string: urlString) else {
            throw PurePlayError.ioError("Invalid URL: \(urlString)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyHeaders(&request)
        let (data, response) = try await session.data(for: request)
        refreshCookies(from: response)
        checkAuthStatus(response: response, data: data)
        return data
    }

    private func applyHeaders(_ request: inout URLRequest) {
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("https://pan.quark.cn", forHTTPHeaderField: "Referer")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
    }

    private func refreshCookies(from response: URLResponse) {
        guard let httpResp = response as? HTTPURLResponse,
              let url = httpResp.url else { return }

        // Use HTTPCookie's built-in parser which handles dates correctly
        let headerFields = httpResp.allHeaderFields as? [String: String] ?? [:]
        let parsedCookies = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: url)

        for cookie in parsedCookies {
            if cookie.name.hasPrefix("__") || cookie.name.hasPrefix("QK") {
                cookies[cookie.name] = cookie.value
            }
        }

        try? keychain.saveCookies(cookies)
    }

    /// 检测 Cookie 是否失效。识别策略：
    ///   1. HTTP 401 / 403 → 立即视为失效
    ///   2. 业务 code: 32003 / 41001 / 41015（夸克常见登录失效码）
    ///   3. message 中含 "unauthorized" / "登录" / "未登录"
    /// 任一命中 → 清空 cookies + 触发 onAuthExpired（主线程）
    private func checkAuthStatus(response: URLResponse, data: Data) {
        var expired = false
        if let http = response as? HTTPURLResponse,
           http.statusCode == 401 || http.statusCode == 403 {
            expired = true
        }
        if !expired,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let code = (json["code"] as? Int)
                ?? (json["status"] as? Int)
                ?? Int((json["code"] as? String) ?? "0")
                ?? 0
            if [32003, 41001, 41015].contains(code) {
                expired = true
            }
            if !expired, let msg = json["message"] as? String {
                let lower = msg.lowercased()
                if lower.contains("unauthorized")
                    || lower.contains("登录失效")
                    || lower.contains("未登录")
                    || lower.contains("登录已失效") {
                    expired = true
                }
            }
        }
        if expired {
            cookies = [:]
            isLoggedIn = false
            keychain.clearCookies()
            let cb = onAuthExpired
            DispatchQueue.main.async { cb?() }
        }
    }

    private var cookieHeader: String {
        cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }
}
