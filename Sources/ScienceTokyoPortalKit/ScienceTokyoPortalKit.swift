import Foundation
import Kanna

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ScienceTokyoPortalLoginError: Error, Equatable {
    case invalidUserNamePage
    case invalidPasswordPage
    case invalidMethodSelectionPage
    case invalidEmailPage
    case invalidTOTPPage
    case invalidFIDO2Page
    case invalidWaitingPage
    case invalidResourceListPage
    case invalidEmailSending
    
    case alreadyLoggedin
}

public struct ScienceTokyoPortal {
    private let httpClient: HTTPClient
    public static let defaultUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"
    
    public init(urlSession: URLSession, userAgent: String = ScienceTokyoPortal.defaultUserAgent) {
        self.httpClient = HTTPClientImpl(urlSession: urlSession, userAgent: userAgent)
    }
    
    /// TitechPortalにログイン
    /// - Parameter account: ログイン情報
    /// - Returns: リソース一覧ページのHTML
    public func loginCommon(account: ScienceTokyoPortalAccount) async throws -> String {
        /// ユーザー名ページの取得
        let userNamePageHtml = try await fetchUserNamePage()
        /// ユーザー名ページのバリデーション(既にログインしている場合)
        if try validateResourceListPage(html: userNamePageHtml){
            throw ScienceTokyoPortalLoginError.alreadyLoggedin
        }
        /// ユーザー名ページのバリデーション
        guard try validateUserNamePage(html: userNamePageHtml) else {
            throw ScienceTokyoPortalLoginError.invalidUserNamePage
        }
        /// Metaタグの取得
        let userNamePageMetas = try parseHTMLMeta(html: userNamePageHtml)
        /// 一部のHTMLを取り出す
        let extractedUserNameHtml = try extractHTML(html: userNamePageHtml, cssSelector: "div#identifier-field-wrapper")
        /// Inputタグの取得
        let userNamePageInputs = try parseHTMLInput(html: extractedUserNameHtml)
        
        /// ユーザー名Formの送信
        let userNamePageSubmitJson = try await submitUserName(htmlInputs: userNamePageInputs, htmlMetas: userNamePageMetas, username: account.username)
        /// ユーザー名submisionのバリデーション
        guard try validateUserNamePageSubmitJson(json: userNamePageSubmitJson, account: account) else {
            throw ScienceTokyoPortalLoginError.invalidUserNamePage
        }
        
        /// 一部のHTMLを取り出す
        let extractedPasswordPageHtml = try extractHTML(html: userNamePageHtml, cssSelector: "form#login")
        /// Inputタグの取得
        let passwordPageInputs = try parseHTMLInput(html: extractedPasswordPageHtml)
        /// PasswordFormの送信
        let passwordPageSubmitScript = try await submitPassword(htmlInputs: passwordPageInputs, htmlMetas: userNamePageMetas, username: account.username, password: account.password)
        guard validateSubmitScript(script: passwordPageSubmitScript) else {
            throw ScienceTokyoPortalLoginError.invalidPasswordPage
        }
        /// 認証方法選択ページの取得
        let methodSelectionPageHtml = try await fetchAuthorizationMethodSelectionPage()
        /// 認証方法選択ページのバリデーション
        guard try validateMethodSelectionPage(html: methodSelectionPageHtml) else {
            throw ScienceTokyoPortalLoginError.invalidMethodSelectionPage
        }
        return methodSelectionPageHtml
    }
    
    /// 認証方法選択ページでEmailを選択した場合(前半)
    /// - Parameters:
    ///   - account: ログイン情報
    ///   - methodSelectionPageHtml: 認証方法選択ページのHTML
    /// - Returns: OTPページのInputタグとMetaタグ
    public func loginEmail(account: ScienceTokyoPortalAccount, methodSelectionPageHtml: String) async throws -> ([HTMLInput],[HTMLMeta]) {
        /// Metaタグの取得
        let methodSelectionPageMetas = try parseHTMLMeta(html: methodSelectionPageHtml)
        /// EmailでOTP送信するリクエストの送信
        let emailSendingResult = try await submitEmailSending(htmlMetas: methodSelectionPageMetas)
        guard validateEmailSending(result: emailSendingResult) else {
            throw ScienceTokyoPortalLoginError.invalidEmailSending
        }
        /// 一部のHTMLを取り出す
        let extractedOTPPageHtml = try extractHTML(html: methodSelectionPageHtml, cssSelector: "form#emailotp-form")
        /// Inputタグの取得
        let otpPageInputs = try parseHTMLInput(html: extractedOTPPageHtml)
        return (otpPageInputs, methodSelectionPageMetas)
    }
    
    /// 認証方法選択ページでTOTPを選択した場合
    /// - Parameters:
    ///   - account: ログイン情報
    ///   - methodSelectionPageHtml: 認証方法選択ページのHTML
    public func loginTOTP(account: ScienceTokyoPortalAccount, methodSelectionPageHtml: String) async throws {
        /// Metaタグの取得
        let methodSelectionPageMetas = try parseHTMLMeta(html: methodSelectionPageHtml)
        /// 一部のHTMLを取り出す
        let extractedOTPPageHtml = try extractHTML(html: methodSelectionPageHtml, cssSelector: "form#totp-form")
        /// Inputタグの取得
        let otpPageInputs = try parseHTMLInput(html: extractedOTPPageHtml)
        /// TOTPを計算した上でリクエストを送信
        let otpPageSubmitScript = try await submitTOTP(htmlInputs: otpPageInputs, htmlMetas: methodSelectionPageMetas, account: account)
        /// OTPページsubmisionのバリデーション
        guard validateSubmitScript(script: otpPageSubmitScript) else {
            throw ScienceTokyoPortalLoginError.invalidTOTPPage
        }
        /// OTPページsubmisionのレスポンスからURLを取得
        let otpPageSubmitURL = try parseScriptToURL(script: otpPageSubmitScript)
        /// otpPageSubmitURLのURLを元に、待機ページを取得
        let waitingPageHtml = try await fetchWaitingPage(url: otpPageSubmitURL)
        /// 待機ページのバリデーション
        guard try validateWaitingPage(html: waitingPageHtml) else {
            throw ScienceTokyoPortalLoginError.invalidWaitingPage
        }
        /// Inputタグの取得
        let waitingPageHtmlInputs = try parseHTMLInput(html: waitingPageHtml)
        /// リソース一覧ページを取得
        let resourceListPageHtml = try await fetchResourceListPage(htmlInputs: waitingPageHtmlInputs, referer: otpPageSubmitURL)
        guard try validateResourceListPage(html: resourceListPageHtml) else {
            throw ScienceTokyoPortalLoginError.invalidResourceListPage
        }
    }
    
    /// EmailでOTPを送信した後の処理．OTPを入力してログインする
    /// - Parameters:
    ///   - htmlInputs: OTPページのInputタグ
    ///   - htmlMetas: OTPページのMetaタグ
    ///   - otp: OTP
    public func latterEmailLogin(htmlInputs: [HTMLInput], htmlMetas: [HTMLMeta], otp: String) async throws {
        /// OTPを送信
        let otpPageSubmitScript = try await submitEmail(htmlInputs: htmlInputs, htmlMetas: htmlMetas, otp: otp)
        /// OTPページsubmisionのバリデーション
        guard validateSubmitScript(script: otpPageSubmitScript) else {
            throw ScienceTokyoPortalLoginError.invalidEmailPage
        }
        /// OTPページsubmisionのレスポンスからURLを取得
        let otpPageSubmitURL = try parseScriptToURL(script: otpPageSubmitScript)
        /// otpPageSubmitURLのURLを元に、待機ページを取得
        let waitingPageHtml = try await fetchWaitingPage(url: otpPageSubmitURL)
        /// 待機ページのバリデーション
        guard try validateWaitingPage(html: waitingPageHtml) else {
            throw ScienceTokyoPortalLoginError.invalidWaitingPage
        }
        /// Inputタグの取得
        let waitingPageHtmlInputs = try parseHTMLInput(html: waitingPageHtml)
        /// リソース一覧ページを取得
        let resourceListPageHtml = try await fetchResourceListPage(htmlInputs: waitingPageHtmlInputs, referer: otpPageSubmitURL)
        /// リソース一覧ページのバリデーション
        guard try validateResourceListPage(html: resourceListPageHtml) else {
            throw ScienceTokyoPortalLoginError.invalidResourceListPage
        }
    }
    
    /// ログイン済みの状態でFIDO2を設定する
    /// 現在のところ，fido2Relay2Jsonでエラーコードが返ってくる
    public func setFIDO2() async throws {
        let fido2PageHtml = try await fetchFIDO2Page()
        let fido2HtmlInput = try parseHTMLInput(html: fido2PageHtml)
        let fido2SettingsJson = try await submitFIDO2Settings(htmlInput: fido2HtmlInput)
        let fido2Relay1Json = try await submitFIDO2Relay1(htmlInput: fido2HtmlInput)
        if let outputJSON = try createCredential(from: fido2Relay1Json) {
            let fido2Relay2Json = try await submitFIDO2Relay2(htmlInput: fido2HtmlInput, jsonBody: outputJSON)
        } else {
        }
    }
    
    /// UsernameとPasswordのみが正しいかチェック
    /// - Parameter username: ユーザー名
    /// - Parameter password: パスワード
    /// - Returns: 正しくログインできればtrue, エラーであればfalseを返す
    public func checkUsernamePassword(username: String, password: String) async throws -> Bool {
        let account = ScienceTokyoPortalAccount(username: username, password: password, totpSecret: nil)
        /// ユーザー名ページの取得
        let userNamePageHtml = try await fetchUserNamePage()
        /// ユーザー名ページのバリデーション
        if try validateResourceListPage(html: userNamePageHtml){
            throw ScienceTokyoPortalLoginError.alreadyLoggedin
        }
        /// ユーザー名ページのバリデーション
        guard try validateUserNamePage(html: userNamePageHtml) else {
            throw ScienceTokyoPortalLoginError.invalidUserNamePage
        }
        /// Metaタグの取得
        let userNamePageMetas = try parseHTMLMeta(html: userNamePageHtml)
        /// 一部のHTMLを取り出す
        let extractedUserNameHtml = try extractHTML(html: userNamePageHtml, cssSelector: "div#identifier-field-wrapper")
        /// Inputタグの取得
        let userNamePageInputs = try parseHTMLInput(html: extractedUserNameHtml)
        
        /// ユーザー名Formの送信
        let userNamePageSubmitJson = try await submitUserName(htmlInputs: userNamePageInputs, htmlMetas: userNamePageMetas, username: account.username)
        /// ユーザー名submisionのバリデーション
        guard try validateUserNamePageSubmitJson(json: userNamePageSubmitJson, account: account) else {
            throw ScienceTokyoPortalLoginError.invalidUserNamePage
        }
        
        /// 一部のHTMLを取り出す
        let extractedPasswordPageHtml = try extractHTML(html: userNamePageHtml, cssSelector: "form#login")
        /// Inputタグの取得
        let passwordPageInputs = try parseHTMLInput(html: extractedPasswordPageHtml)
        /// PasswordFormの送信
        let passwordPageSubmitScript = try await submitPassword(htmlInputs: passwordPageInputs, htmlMetas: userNamePageMetas, username: account.username, password: account.password)
        return validateSubmitScript(script: passwordPageSubmitScript)
    }


    /// ユーザー名ページを取得
    /// - Returns: ユーザー名ページのHTML
    private func fetchUserNamePage() async throws -> String {
        let request = UserNamePageRequest()
        
        return try await httpClient.send(request)
    }
    
    /// ユーザー名formを送信
    /// - Parameters:
    ///   - htmlInputs: ユーザー名ページのInputタグ
    ///   - htmlMetas: ユーザー名ページのMetaタグ
    ///   - username: ユーザー名
    /// - Returns: ユーザー名formの送信結果    
    private func submitUserName(htmlInputs: [HTMLInput], htmlMetas: [HTMLMeta], username: String) async throws -> String {
        let htmlMetas = htmlMetas.filter{ $0.name == "csrf-token" }.map{ HTMLMeta(name: "X-CSRF-Token", content: $0.content )} // csrf-tokenを取り出す
        let htmlInputs = inject(htmlInputs, username: username, password: "")
        let request = UserNameSubmitRequest(htmlInputs: htmlInputs, htmlMetas: htmlMetas)
        
        return try await httpClient.send(request)
    }
    
    /// PasswordFormを送信
    /// - Parameters:
    ///   - htmlInputs: ユーザー名ページのInputタグ
    ///   - htmlMetas: ユーザー名ページのMetaタグ
    ///   - username: ユーザー名
    ///   - password: パスワード
    /// - Returns: PasswordFormの送信結果
    private func submitPassword(htmlInputs: [HTMLInput], htmlMetas: [HTMLMeta], username: String, password: String) async throws -> String {
        let htmlMetas = htmlMetas.filter{ $0.name == "csrf-token" }.map{ HTMLMeta(name: "X-CSRF-Token", content: $0.content )} // csrf-tokenを取り出す
        let injectedHtmlInputs = inject(htmlInputs, username: username, password: password)
        
        let request = PasswordSubmitRequest(htmlInputs: injectedHtmlInputs, htmlMetas: htmlMetas)
        
        return try await httpClient.send(request)
    }
    
    /// 認証方法選択ページを取得
    /// - Returns: 認証方法選択ページのHTML
    private func fetchAuthorizationMethodSelectionPage() async throws -> String {
        let request = AuthorizationMethodSelectionPageRequest()
        
        return try await httpClient.send(request)
    }
    
    /// EmailでOTPを送信
    /// - Parameter htmlMetas: 認証方法選択ページのMetaタグ
    /// - Returns: JSON形式のOTP送信結果
    private func submitEmailSending(htmlMetas: [HTMLMeta]) async throws -> String {
        let htmlMetas = htmlMetas.filter{ $0.name == "csrf-token" }.map{ HTMLMeta(name: "X-CSRF-Token", content: $0.content )} // csrf-tokenを取り出す
        let request = EmailSendingSubmitRequest(htmlMetas: htmlMetas)
        return try await httpClient.send(request)
    }
    
    /// OTPを送信
    /// - Parameters:
    ///   - htmlInputs: 認証方法選択ページのInputタグ
    ///   - htmlMetas: 認証方法選択ページのMetaタグ
    ///   - otp: OTP
    /// - Returns: OTPFormの送信結果
    private func submitEmail(htmlInputs: [HTMLInput], htmlMetas: [HTMLMeta], otp: String) async throws -> String {
        let htmlMetas = htmlMetas.filter{ $0.name == "csrf-token" }.map{ HTMLMeta(name: "X-CSRF-Token", content: $0.content )} // csrf-tokenを取り出す
        let injectedHtmlInputs = inject(htmlInputs, username: otp, password: "")
        let request = OTPSubmitRequest(htmlInputs: injectedHtmlInputs, htmlMetas: htmlMetas)
        return try await httpClient.send(request)
    }
    
    /// TOTPを送信
    /// - Parameters:
    ///   - htmlInputs: 認証方法選択ページのInputタグ
    ///   - htmlMetas: 認証方法選択ページのMetaタグ
    ///   - account: ログイン情報
    /// - Returns: OTPFormの送信結果
    private func submitTOTP(htmlInputs: [HTMLInput], htmlMetas: [HTMLMeta], account: ScienceTokyoPortalAccount) async throws -> String {
        let htmlMetas = htmlMetas.filter{ $0.name == "csrf-token" }.map{ HTMLMeta(name: "X-CSRF-Token", content: $0.content )} // csrf-tokenを取り出す
        guard let accountTotp = account.totpSecret else {
            throw ScienceTokyoPortalLoginError.invalidUserNamePage
        }
        let otp = try calculateTOTP(secret: accountTotp)
        let injectedHtmlInputs = inject(htmlInputs, username: otp, password: "")
        let request = OTPSubmitRequest(htmlInputs: injectedHtmlInputs, htmlMetas: htmlMetas)
        return try await httpClient.send(request)
    }
    
    /// 待機ページを取得
    /// - Parameter url: 待機ページのURL
    /// - Returns: 待機ページのHTML
    private func fetchWaitingPage(url: String) async throws -> String {
        let request = WaitingPageRequest(url: URL(string: url)!)
        return try await httpClient.send(request)
    }
    
    /// リソース一覧ページを取得
    /// - Parameters:
    ///   - htmlInputs: 待機ページのInputタグ
    ///   - referer: 待機ページのURL
    /// - Returns: リソース一覧ページのHTML
    private func fetchResourceListPage(htmlInputs: [HTMLInput], referer: String) async throws -> String {
        let request = ResourceListPageRequest(htmlInputs: htmlInputs, referer: referer)
        return try await httpClient.send(request)
    }
    
    /// FIDO2設定ページを取得
    /// - Returns: FIDO2設定ページのHTML
    private func fetchFIDO2Page() async throws -> String {
        let request = FIDO2PageRequest()
        return try await httpClient.send(request)
    }
    
    /// FIDO2設定を送信
    /// - Parameter htmlInput: FIDO2設定ページのInputタグ
    /// - Returns: FIDO2設定の送信結果
    private func submitFIDO2Settings(htmlInput: [HTMLInput]) async throws -> String {
        let htmlMetas = htmlInput.filter{ $0.name == "_csrf" }.map{ HTMLMeta(name: "x-csrf-token", content: $0.value )} // csrf-tokenを取り出す
        let request = FIDO2SettingsRequest(htmlMetas: htmlMetas)
        return try await httpClient.send(request)
    }
    
    /// FIDO2 Relay(1回目)を送信
    /// - Parameter htmlInput: FIDO2設定ページのInputタグ
    /// - Returns: FIDO2 Relay1の送信結果
    private func submitFIDO2Relay1(htmlInput: [HTMLInput]) async throws -> String {
        let htmlMetas = htmlInput.filter{ $0.name == "_csrf" }.map{ HTMLMeta(name: "X-CSRF-Token", content: $0.value )} // csrf-tokenを取り出す
        let request = FIDO2Relay1Request(htmlMetas: htmlMetas)
        return try await httpClient.send(request)
    }
    
    /// FIDO2 Relay(2回目)を送信
    /// - Parameters:
    ///   - htmlInput: FIDO2設定ページのInputタグ
    ///   - jsonBody: FIDO2 Relay1のレスポンスから計算したJSON
    /// - Returns: FIDO2 Relay2の送信結果
    private func submitFIDO2Relay2(htmlInput: [HTMLInput], jsonBody: [String: Any]) async throws -> String {
        let htmlMetas = htmlInput.filter{ $0.name == "_csrf" }.map{ HTMLMeta(name: "X-CSRF-Token", content: $0.value )} // csrf-tokenを取り出す
        let request = FIDO2Relay2Request(htmlMetas: htmlMetas, jsonBody: jsonBody)
        return try await httpClient.send(request)
    }
    
    /// ユーザー名ページのバリデーション
    /// - Parameter html: ユーザー名ページのHTML
    /// - Returns: ユーザー名ページが正しい場合はtrue, エラーであればfalseを返す
    private func validateUserNamePage(html: String) throws -> Bool {
        let doc = try HTML(html: html, encoding: .utf8)
        
        let bodyHtml = doc.css("body").first?.innerHTML ?? ""
        
        return bodyHtml.contains("Please set your e-mail address for password reissue to an e-mail other than m.isct.ac.jp.") || bodyHtml.contains("パスワード再発行用メールアドレスをm.isct.ac.jp以外のメールアドレスに忘れず必ず設定してください。")
    }
    
    /// ユーザー名Formのsubmisionのバリデーション
    /// - Parameters:
    ///   - json: ユーザー名FormのsubmisionのJSON
    ///   - account: ログイン情報
    /// - Returns: ユーザー名Formのsubmisionが正しい場合はtrue, エラーであればfalseを返す
    private func validateUserNamePageSubmitJson(json: String, account: ScienceTokyoPortalAccount) throws -> Bool {
        let jsonObject = try JSONSerialization.jsonObject(with: Data(json.utf8), options: [])
        guard let jsonDict = jsonObject as? [String: Any] else {
            return false
        }
        guard let password = jsonDict["password"] as? Bool else {
            return false
        }
        guard let username = jsonDict["identifier"] as? String else {
            return false
        }
        return password && username == account.username
    }
    
    /// PasswordFormのsubmisionのバリデーション
    /// - Parameter script: PasswordFormのsubmisionのscript
    /// - Returns: PasswordFormのsubmisionが正しい場合はtrue, エラーであればfalseを返す
    private func validateSubmitScript(script: String) -> Bool {
        return script.contains("window.location=")
    }
    
    /// 認証方法選択ページのバリデーション
    /// - Parameter html: 認証方法選択ページのHTML
    /// - Returns: 認証方法選択ページが正しい場合はtrue, エラーであればfalseを返す
    /// - Note: 認証方法選択ページは、認証方法を選択するためのページであることを確認する
    private func validateMethodSelectionPage(html: String) throws -> Bool {
        let doc = try HTML(html: html, encoding: .utf8)
        
        let bodyHtml = doc.css("body").first?.innerHTML ?? ""
        
        return bodyHtml.contains("Please select an authentication method.") || bodyHtml.contains("認証方法を選択してください。")
    }

    /// 待機ページのバリデーション
    /// - Parameter html: 待機ページのHTML
    /// - Returns: 待機ページが正しい場合はtrue, エラーであればfalseを返す
    private func validateWaitingPage(html: String) throws -> Bool {
        let doc = try HTML(html: html, encoding: .utf8)
        
        let bodyHtml = doc.css("body").first?.innerHTML ?? ""
        
        return bodyHtml.contains("Please wait for a moment") || bodyHtml.contains("しばらくお待ちください。")
    }
    
    /// リソース一覧ページのバリデーション
    /// - Parameter html: リソース一覧ページのHTML
    /// - Returns: リソース一覧ページが正しい場合はtrue, エラーであればfalseを返す
    private func validateResourceListPage(html: String) throws -> Bool {
        let doc = try HTML(html: html, encoding: .utf8)
        
        let bodyHtml = doc.css("body").first?.innerHTML ?? ""
        
        return bodyHtml.contains("Account") || bodyHtml.contains("アカウント")
    }
    
    /// Email送信のバリデーション
    /// - Parameter result: Email送信の結果
    /// - Returns: Email送信が正しい場合はtrue, エラーであればfalseを返す
    private func validateEmailSending(result: String) -> Bool {
        return result.contains("succeeded")
    }
    
    /// HTMLから特定の部分を抽出する
    /// - Parameters:
    ///   - html: HTML
    ///   - cssSelector: CSSセレクタ
    /// - Returns: 抽出したHTML
    func extractHTML(html: String, cssSelector: String) throws -> String {
        let doc = try HTML(html: html, encoding: .utf8)
        return doc.body?.css(cssSelector).first?.innerHTML ?? ""
    }
    
    /// HTMLからInputタグを取得する
    /// - Parameter html: HTML
    /// - Returns: Inputタグの配列
    func parseHTMLInput(html: String) throws -> [HTMLInput] {
        let doc = try HTML(html: html, encoding: .utf8)
        
        return doc.css("input").map {
            HTMLInput(
                name: $0["name"] ?? "",
                type: HTMLInputType(rawValue: $0["type"] ?? "") ?? .text,
                value: $0["value"] ?? ""
            )
        }
    }
    
    /// HTMLからSelectタグを取得する
    /// - Parameter html: HTML
    /// - Returns: Selectタグの配列
    func parseHTMLSelect(html: String) throws -> [HTMLSelect] {
        let doc = try HTML(html: html, encoding: .utf8)
        
        return doc.css("select").map {
            HTMLSelect(
                name: $0["name"] ?? "",
                values: $0.css("option").map { $0["value"] ?? "" }
            )
        }
    }
    
    /// HTMLからMetaタグを取得する
    /// - Parameter html: HTML
    /// - Returns: Metaタグの配列
    func parseHTMLMeta(html: String) throws -> [HTMLMeta] {
        let doc = try HTML(html: html, encoding: .utf8)
        
        return doc.css("meta").map {
            HTMLMeta(
                name: $0["name"] ?? "",
                content: $0["content"] ?? ""
            )
        }
    }
    
    /// HTMLからScriptタグを取得する
    /// - Parameter html: HTML
    /// - Returns: Scriptタグの配列
    func parseScriptToURL(script: String) throws -> String {
        let components = script.components(separatedBy: "\"")
        return components[1]
    }
    
    /// HTMLInputの配列に値を注入する
    /// - Parameters:
    ///   - inputs: HTMLInputの配列
    ///   - username: ユーザー名
    ///   - password: パスワード
    /// - Returns: 値を注入したHTMLInputの配列
    func inject(_ inputs: [HTMLInput], username: String, password: String) -> [HTMLInput] {
        var inputs = inputs
        if let firstTextInput = inputs.first(where: { $0.type == .text })
        {
            inputs = inputs.map {
                if $0 == firstTextInput {
                    var newInput = $0
                    newInput.value = username
                    return newInput
                }
                return $0
            }
        }
        if let firstPasswordInput = inputs.first(where: { $0.type == .password })
        {
            inputs = inputs.map {
                if $0 == firstPasswordInput {
                    var newInput = $0
                    newInput.value = password
                    return newInput
                }
                return $0
            }
        }
        return inputs
    }
}
