import AppKit
import ManpingCore
import CoreImage.CIFilterBuiltins
import SwiftUI
import WebKit

struct LoginView: View {
  @ObservedObject var model: AppModel
  @State private var qrImage: NSImage?
  @State private var status = "正在获取二维码"
  @State private var webLogin = false
  @State private var error: String?
  @State private var qrGeneration = 0
  var body: some View {
    VStack(spacing: 16) {
      HStack {
        Text("登录哔哩哔哩").font(Theme.Font.largeTitle)
        Spacer()
        Button { model.showingLogin = false } label: { Image(systemName: "xmark") }
          .buttonStyle(AppButtonStyle(role: .plain, size: .small, iconOnly: true)).keyboardShortcut(.cancelAction).help("关闭")
      }
      if webLogin {
        CookieWebLogin(
          service: model.service,
          onAuthenticated: { token in Task { await model.loginCompleted(token: token) } },
          onError: {
            error = $0
            model.error = $0
          }
        ).frame(width: 640, height: 560)
      } else {
        if let qrImage {
          Image(nsImage: qrImage).interpolation(.none).resizable().frame(width: 220, height: 220)
            .padding(14).background(.white, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous).strokeBorder(.black.opacity(0.08), lineWidth: 0.5))
        } else {
          ProgressView().frame(width: 244, height: 244)
        }
        Text(status).font(Theme.Font.headline)
        Text("请用哔哩哔哩手机 App 扫码并确认登录").font(Theme.Font.caption).foregroundStyle(.secondary)
      }
      if let error { InlineErrorText(message: error) }
      HStack(spacing: 8) {
      if !webLogin {
        Button("重新获取二维码") {
          error = nil
          qrImage = nil
          status = "正在获取二维码"
          qrGeneration += 1
        }.buttonStyle(AppButtonStyle(size: .small))
      }
      Button(webLogin ? "改用二维码" : "使用网页登录") {
        error = nil
        status = webLogin ? "正在获取二维码" : "正在打开网页登录"
        webLogin.toggle()
      }.buttonStyle(AppButtonStyle(role: .plain, size: .small))
      }
    }.padding(24).frame(minWidth: 450).task(id: "\(webLogin)-\(qrGeneration)") {
      guard !webLogin else { return }
      do {
        let qr = try await model.service.beginQR()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(qr.url.absoluteString.utf8)
        filter.correctionLevel = "M"
        if let image = filter.outputImage,
          let cg = CIContext().createCGImage(
            image.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
            from: image.extent.applying(CGAffineTransform(scaleX: 8, y: 8)))
        {
          qrImage = NSImage(cgImage: cg, size: NSSize(width: 220, height: 220))
        }
        while !Task.isCancelled {
          try await Task.sleep(nanoseconds: 2_000_000_000)
          switch try await model.service.pollQR(qr.key, token: qr.token) {
          case .waiting: status = "等待扫码"
          case .scanned: status = "已扫码，请在手机确认"
          case .expired:
            status = "二维码已过期，请重新获取"
            return
          case .success:
            await model.loginCompleted(token: qr.token)
            return
          }
        }
      } catch is CancellationError {} catch {
        self.error = "认证请求失败，请重试"
        status = "没能获取二维码，可重试或使用网页登录"
      }
    }
  }
}
struct CookieWebLogin: NSViewRepresentable {
  let service: BiliService
  let onAuthenticated: (UInt64) -> Void
  let onError: (String) -> Void
  final class Coordinator: NSObject, WKNavigationDelegate {
    let owner: CookieWebLogin
    var token: UInt64 = 0
    var active = true
    var loginTask: Task<Void, Never>?
    var startupTask: Task<Void, Never>?
    let callbacks = AuthCallbackGate()
    init(_ owner: CookieWebLogin) { self.owner = owner }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
        guard let self, self.active,
          cookies.contains(where: {
            $0.name == "SESSDATA"
              && ($0.domain == "bilibili.com" || $0.domain.hasSuffix(".bilibili.com"))
          })
        else { return }
        guard self.loginTask == nil else { return }
        let generation = self.callbacks.generation
        self.loginTask = Task { @MainActor in
          defer { self.loginTask = nil }
          guard self.active, self.callbacks.accepts(generation) else { return }
          do {
            if try await self.owner.service.synchronizeCookies(cookies, token: self.token),
              self.active, self.callbacks.accepts(generation)
            {
              do {
                _ = try await self.owner.service.authorizeWebCookies(token: self.token)
              } catch is CancellationError { return } catch {
                guard self.active, self.callbacks.accepts(generation) else { return }
                self.owner.onError("网页登录有效，但 App 授权转换失败，请重新登录")
              }
              guard self.active, self.callbacks.accepts(generation) else { return }
              self.owner.onAuthenticated(self.token)
            }
          } catch is CancellationError {} catch {
            if self.active, self.callbacks.accepts(generation) {
              self.owner.onError("无法保存登录凭据，请检查磁盘空间与「应用程序支持」目录权限")
            }
          }
        }
      }
    }
    func webView(
      _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
      withError error: Error
    ) { if active { owner.onError("没能加载网页登录，请重试") } }
  }
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> WKWebView {
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    let view = WKWebView(frame: .zero, configuration: config)
    view.navigationDelegate = context.coordinator
    context.coordinator.startupTask = Task { @MainActor in
      guard context.coordinator.active, !Task.isCancelled else { return }
      context.coordinator.token = await service.beginLogin()
      let cookies = await service.loginCookies()
      for cookie in cookies {
        guard context.coordinator.active, !Task.isCancelled else { return }
        await config.websiteDataStore.httpCookieStore.setCookie(cookie)
      }
      if context.coordinator.active {
        view.load(URLRequest(url: URL(string: "https://passport.bilibili.com/login")!))
      }
    }
    return view
  }
  func updateNSView(_ view: WKWebView, context: Context) {}
  static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
    coordinator.active = false
    coordinator.callbacks.invalidate()
    coordinator.loginTask?.cancel()
    coordinator.startupTask?.cancel()
    let store = view.configuration.websiteDataStore
    store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    {}
    view.stopLoading()
    view.navigationDelegate = nil
  }
}
