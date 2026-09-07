import 'dart:io';

/// O que a plataforma consegue oferecer de navegador (plano 58, decisão B).
///
/// - [inline]: webview embutida na árvore de widgets (WKWebView no macOS/iOS,
///   WebView2 no Windows, Android WebView no Android, WPE WebKit no Linux, via
///   flutter_inappwebview) — pane de navegador e preview de markdown/HTML.
/// - [systemBrowser]: sem webview — "abrir navegador" delega ao browser do SO
///   via url_launcher e a UI **não** oferece o que não existe (sem botão
///   morto; preview de .md segue no renderer Flutter).
enum BrowserCapability {
  inline,
  systemBrowser;

  /// Inline em todas as plataformas. O Linux entrou com o
  /// `flutter_inappwebview_linux` (WPE WebKit, 6.2.0-beta) — spike de
  /// 2026-09-07. `COCKPIT_NO_WEBVIEW=1` força [systemBrowser] em qualquer
  /// plataforma, pra validar o caminho degradado (ou escapar se o WPE falhar).
  static BrowserCapability resolve() =>
      Platform.environment['COCKPIT_NO_WEBVIEW'] == '1'
      ? systemBrowser
      : inline;

  bool get isInline => this == inline;
}
