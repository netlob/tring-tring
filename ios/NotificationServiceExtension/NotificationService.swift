import OSLog
import UniformTypeIdentifiers
import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
    private let log = Logger(subsystem: "dev.sjoerd.tringtring.NotificationServiceExtension", category: "nse")
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttempt: UNMutableNotificationContent?
    private var task: Task<Void, Never>?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        self.bestAttempt = (request.content.mutableCopy() as? UNMutableNotificationContent)
        guard let content = bestAttempt else {
            contentHandler(request.content)
            return
        }

        let userInfo = content.userInfo
        let imageURLString = userInfo["image-url"] as? String
        let imageDataString = userInfo["image-data"] as? String

        guard imageURLString != nil || imageDataString != nil else {
            contentHandler(content)
            return
        }

        task = Task { [log] in
            if let attachment = await Self.makeAttachment(imageURL: imageURLString, imageData: imageDataString, identifier: request.identifier, log: log) {
                content.attachments = [attachment]
            }
            contentHandler(content)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        task?.cancel()
        if let handler = contentHandler, let content = bestAttempt {
            handler(content)
        }
    }

    private static func makeAttachment(imageURL: String?, imageData: String?, identifier: String, log: Logger) async -> UNNotificationAttachment? {
        if let urlString = imageURL,
           let url = URL(string: urlString),
           url.scheme?.lowercased() == "https" {
            return await downloadAttachment(from: url, identifier: identifier, log: log)
        }
        if let b64 = imageData, let data = Data(base64Encoded: b64) {
            return makeAttachment(from: data, contentType: nil, identifier: identifier, log: log)
        }
        log.warning("no usable image source")
        return nil
    }

    private static func downloadAttachment(from url: URL, identifier: String, log: Logger) async -> UNNotificationAttachment? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                log.warning("image download non-2xx")
                return nil
            }
            let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces)
            return makeAttachment(from: data, contentType: contentType, identifier: identifier, log: log)
        } catch {
            log.warning("image download failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    // The NSE process is limited to ~24 MB resident; cap attachments at 10 MB so we never OOM mid-write.
    private static let maxBytes = 10 * 1024 * 1024

    private static func makeAttachment(from data: Data, contentType: String?, identifier: String, log: Logger) -> UNNotificationAttachment? {
        guard data.count <= maxBytes else {
            log.warning("attachment exceeds size cap")
            return nil
        }
        let ext = fileExtension(for: contentType, sniffing: data)
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dest = tmpDir.appendingPathComponent("nse-\(identifier)-\(UUID().uuidString)").appendingPathExtension(ext)
        do {
            try data.write(to: dest)
            let attachment = try UNNotificationAttachment(identifier: "image", url: dest, options: nil)
            return attachment
        } catch {
            log.warning("attachment write/build failed")
            return nil
        }
    }

    private static func fileExtension(for contentType: String?, sniffing data: Data) -> String {
        if let ct = contentType?.lowercased() {
            if ct.contains("png") { return "png" }
            if ct.contains("jpeg") || ct.contains("jpg") { return "jpg" }
            if ct.contains("gif") { return "gif" }
            if ct.contains("heic") { return "heic" }
            if ct.contains("webp") { return "webp" }
        }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if data.starts(with: [0x47, 0x49, 0x46]) { return "gif" }
        return "img"
    }
}
