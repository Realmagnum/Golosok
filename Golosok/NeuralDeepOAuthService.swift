import Foundation
import AppKit
import Darwin

/// Сервис авторизации в Neuraldeep (NP) через веб-браузер и локальный loopback-сервер
/// (протокол совместим с официальным CLI-авторизатором хаба Neuraldeep / Coddy Agent).
final class NeuralDeepOAuthService: ObservableObject {
    static let shared = NeuralDeepOAuthService()

    @Published private(set) var isAuthenticating = false
    @Published private(set) var authStatusMessage: String?

    private var currentSocket: Int32 = -1
    private var isCancelled = false
    private let queue = DispatchQueue(label: "Golosok.NeuralDeepOAuth", qos: .userInitiated)

    private static let hubURL = "https://hub.neuraldeep.ru"
    private static let clientID = "golosok"

    private init() {}

    func startBrowserLogin(completion: @escaping (Result<String, Error>) -> Void) {
        guard !isAuthenticating else { return }
        isCancelled = false
        isAuthenticating = true
        authStatusMessage = "Ожидание авторизации в браузере…"

        queue.async { [weak self] in
            guard let self else { return }
            self.runOAuthServer(completion: completion)
        }
    }

    func cancel() {
        isCancelled = true
        if currentSocket >= 0 {
            Darwin.close(currentSocket)
            currentSocket = -1
        }
        DispatchQueue.main.async {
            self.isAuthenticating = false
            self.authStatusMessage = nil
        }
    }

    private func runOAuthServer(completion: @escaping (Result<String, Error>) -> Void) {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else {
            notifyFailure(error: NSError(domain: "NeuralDeepOAuth", code: 1, userInfo: [NSLocalizedDescriptionKey: "Не удалось создать сетевой сокет"]), completion: completion)
            return
        }
        currentSocket = sock

        var opt: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0 // Случайный свободный порт

        let bindRes = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindRes >= 0 else {
            Darwin.close(sock)
            currentSocket = -1
            notifyFailure(error: NSError(domain: "NeuralDeepOAuth", code: 2, userInfo: [NSLocalizedDescriptionKey: "Не удалось привязать сокет к 127.0.0.1"]), completion: completion)
            return
        }

        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = getsockname(sock, $0, &len)
            }
        }
        let port = UInt16(bigEndian: addr.sin_port)

        guard listen(sock, 1) >= 0 else {
            Darwin.close(sock)
            currentSocket = -1
            notifyFailure(error: NSError(domain: "NeuralDeepOAuth", code: 3, userInfo: [NSLocalizedDescriptionKey: "Ошибка прослушивания порта"]), completion: completion)
            return
        }

        // Генерируем 32 случайных байта для state (защита от CSRF)
        var randomBytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        let state = Data(randomBytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        let authURLString = "\(Self.hubURL)/api/cli/auth/start?port=\(port)&state=\(state)&client=\(Self.clientID)"
        guard let authURL = URL(string: authURLString) else {
            Darwin.close(sock)
            currentSocket = -1
            notifyFailure(error: NSError(domain: "NeuralDeepOAuth", code: 4, userInfo: [NSLocalizedDescriptionKey: "Некорректный URL авторизации"]), completion: completion)
            return
        }

        DispatchQueue.main.async {
            NSWorkspace.shared.open(authURL)
        }

        // Ожидаем входящее подключение с таймаутом (10 минут)
        var timeout = timeval(tv_sec: 600, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var clientAddr = sockaddr_in()
        var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let clientSock = withUnsafeMutablePointer(to: &clientAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                accept(sock, $0, &clientLen)
            }
        }

        Darwin.close(sock)
        currentSocket = -1

        guard clientSock >= 0 else {
            if isCancelled { return }
            notifyFailure(error: NSError(domain: "NeuralDeepOAuth", code: 5, userInfo: [NSLocalizedDescriptionKey: "Время ожидания авторизации истекло или вход отменен"]), completion: completion)
            return
        }

        var buffer = [UInt8](repeating: 0, count: 8192)
        let bytesRead = read(clientSock, &buffer, buffer.count)
        guard bytesRead > 0, let requestString = String(bytes: buffer.prefix(bytesRead), encoding: .utf8) else {
            Darwin.close(clientSock)
            notifyFailure(error: NSError(domain: "NeuralDeepOAuth", code: 6, userInfo: [NSLocalizedDescriptionKey: "Пустой ответ от браузера"]), completion: completion)
            return
        }

        // Парсим GET строку запроса
        // Пример: GET /cb?state=XYZ&key=sk-... HTTP/1.1
        let firstLine = requestString.components(separatedBy: "\r\n").first ?? ""
        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2, let uri = URLComponents(string: "http://127.0.0.1" + parts[1]) else {
            sendResponse(to: clientSock, success: false, message: "Некорректный запрос")
            Darwin.close(clientSock)
            notifyFailure(error: NSError(domain: "NeuralDeepOAuth", code: 7, userInfo: [NSLocalizedDescriptionKey: "Некорректный URL запроса"]), completion: completion)
            return
        }

        let queryItems = uri.queryItems ?? []
        let receivedState = queryItems.first(where: { $0.name == "state" })?.value ?? ""
        let receivedKey = queryItems.first(where: { $0.name == "key" })?.value ?? ""

        guard receivedState == state else {
            sendResponse(to: clientSock, success: false, message: "Ошибка проверки безопасности (state mismatch). Попробуйте снова.")
            Darwin.close(clientSock)
            notifyFailure(error: NSError(domain: "NeuralDeepOAuth", code: 8, userInfo: [NSLocalizedDescriptionKey: "Проверка безопасности (state) не прошла"]), completion: completion)
            return
        }

        guard !receivedKey.isEmpty else {
            sendResponse(to: clientSock, success: false, message: "Ключ не был передан сервисом авторизации.")
            Darwin.close(clientSock)
            notifyFailure(error: NSError(domain: "NeuralDeepOAuth", code: 9, userInfo: [NSLocalizedDescriptionKey: "Хаб не передал API-ключ"]), completion: completion)
            return
        }

        sendResponse(to: clientSock, success: true, message: "Голосок успешно подключён к Neuraldeep!<br><small style='color:#a1a1aa'>Можно закрыть эту вкладку и вернуться в приложение.</small>")
        Darwin.close(clientSock)

        DispatchQueue.main.async { [weak self] in
            self?.isAuthenticating = false
            self?.authStatusMessage = "Успешно подключено!"
            completion(.success(receivedKey))
        }
    }

    private func sendResponse(to socket: Int32, success: Bool, message: String) {
        let title = success ? "Вход выполнен" : "Ошибка входа"
        let color = success ? "#10B981" : "#EF4444"
        let html = """
        <!doctype html>
        <html lang="ru">
        <head>
            <meta charset="utf-8">
            <title>\(title)</title>
            <style>
                body {
                    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
                    background: #09090b;
                    color: #fafafa;
                    display: flex;
                    align-items: center;
                    justify-content: center;
                    height: 100vh;
                    margin: 0;
                    text-align: center;
                }
                .card {
                    background: #18181b;
                    border: 1px solid #27272a;
                    border-radius: 20px;
                    padding: 40px;
                    max-width: 440px;
                    box-shadow: 0 10px 30px rgba(0,0,0,0.5);
                }
                h2 { color: \(color); margin-top: 0; font-size: 22px; }
                p { font-size: 15px; line-height: 1.5; color: #d4d4d8; }
            </style>
        </head>
        <body>
            <div class="card">
                <h2>\(title)</h2>
                <p>\(message)</p>
            </div>
        </body>
        </html>
        """

        let response = """
        HTTP/1.1 \(success ? "200 OK" : "400 Bad Request")\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(html.utf8.count)\r
        Connection: close\r
        Cache-Control: no-store\r
        \r
        \(html)
        """

        _ = response.withCString {
            Darwin.write(socket, $0, strlen($0))
        }
    }

    private func notifyFailure(error: Error, completion: @escaping (Result<String, Error>) -> Void) {
        DispatchQueue.main.async { [weak self] in
            self?.isAuthenticating = false
            self?.authStatusMessage = nil
            completion(.failure(error))
        }
    }
}
