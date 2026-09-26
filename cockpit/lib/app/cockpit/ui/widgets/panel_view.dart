import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:cockpit/app/cockpit/domain/entities/browser_capability.dart';
import 'package:cockpit/app/cockpit/domain/entities/file_view.dart';
import 'package:cockpit/app/cockpit/domain/entities/panel_document.dart';
import 'package:cockpit/app/cockpit/ui/session/file_viewer_session.dart';
import 'package:cockpit/app/core/ui/themes/themes.dart';
import 'package:cockpit/app/core/ui/widgets/unzoomed_native_view.dart';
import 'package:cockpit/i18n/strings.g.dart';
import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:url_launcher/url_launcher.dart' as launcher;

/// Aba de um arquivo `.panel` (plano 67): o HTML do arquivo numa webview viva,
/// com `window.cockpit(line)` injetado no início do documento. Cada chamada
/// vira `cockpit <line>` na máquina (via [onCall], que a VM resolve spawnando
/// a CLI interna) e a Promise recebe `{ok, code, stdout, stderr, json}`.
///
/// Recursos relativos (`<img src="a.png">`, `<script src="app.js">`) saem pelo
/// scheme `ckp-panel://<sessão>/`, servido só de dentro da pasta do arquivo.
/// O tema do app entra como CSS variables `--ckp-*` no `:root`, re-injetadas
/// na troca de tema; a página as usa se quiser.
class PanelView extends StatefulWidget {
  const PanelView({super.key, required this.session, required this.onCall});

  final FileViewerSession session;

  /// Executa `cockpit <line>` com cwd [cwd] e devolve o mapa que a página vê.
  final Future<Map<String, Object?>> Function(String line, String cwd) onCall;

  @override
  State<PanelView> createState() => _PanelViewState();
}

class _PanelViewState extends State<PanelView> {
  static final bool _inline = BrowserCapability.resolve().isInline;

  /// Script da ponte, lido uma vez por processo.
  static String? _bridge;

  InAppWebViewController? _web;
  bool _loaded = false;
  PanelDocument? _doc;
  Map<String, String>? _pushedTheme;

  String get _docDir {
    final p = widget.session.path;
    return p.contains('/') ? p.substring(0, p.lastIndexOf('/')) : p;
  }

  /// cwd do `exec`/CLI: `cwd:` do front-matter relativo à pasta do arquivo.
  String get _cwd {
    final rel = _doc?.cwd;
    if (rel == null || rel.isEmpty) return _docDir;
    if (rel.startsWith('/') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(rel)) {
      return rel;
    }
    return File('$_docDir/$rel').absolute.path;
  }

  String get _baseUrl => 'ckp-panel://${widget.session.id}/';

  @override
  void initState() {
    super.initState();
    _parse();
    widget.session.addListener(_onSession);
    if (_bridge == null) {
      rootBundle.loadString('assets/panel/bridge.js').then((js) {
        _bridge = js;
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void didUpdateWidget(PanelView old) {
    super.didUpdateWidget(old);
    if (old.session != widget.session) {
      old.session.removeListener(_onSession);
      widget.session.addListener(_onSession);
      _parse();
    }
  }

  @override
  void dispose() {
    widget.session.removeListener(_onSession);
    widget.session.setDocumentTitle(null);
    super.dispose();
  }

  String get _rawText => switch (widget.session.view) {
    FileViewText(:final text) => text,
    FileViewMarkdown(:final text) => text,
    FileViewSvg(:final text) => text,
    _ => '',
  };

  void _parse() {
    final doc = PanelDocument.parse(_rawText);
    _doc = doc;
    widget.session.setDocumentTitle(doc.title);
  }

  /// Conteúdo relido do disco (watcher) → recarrega a página, se o documento
  /// pede (`reload: true`, o default).
  void _onSession() {
    final before = _doc?.body;
    _parse();
    final doc = _doc!;
    if (!doc.reload || doc.body == before) return;
    final web = _web;
    if (web == null || !_loaded) return;
    unawaited(
      web.loadData(
        data: doc.body,
        baseUrl: WebUri(_baseUrl),
        mimeType: 'text/html',
        encoding: 'utf-8',
      ),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final vars = _themeVars(context);
    if (mapEquals(vars, _pushedTheme)) return;
    _pushedTheme = vars;
    unawaited(_pushTheme(vars));
  }

  Future<void> _pushTheme(Map<String, String> vars) async {
    final web = _web;
    if (web == null || !_loaded || !mounted) return;
    await web.evaluateJavascript(
      source:
          'window.cockpit && window.cockpit.__setTheme(${jsonEncode(vars)});',
    );
  }

  Map<String, String> _themeVars(BuildContext context) {
    final colors = context.colors;
    String hex(Color c) =>
        '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
    return {
      '--ckp-bg': hex(colors.panel),
      '--ckp-text': hex(colors.text),
      '--ckp-text-muted': hex(colors.text3),
      '--ckp-border': hex(colors.border),
      '--ckp-code-bg': hex(colors.panel3),
      '--ckp-link': hex(colors.accent),
      '--ckp-accent': hex(colors.accent),
    };
  }

  /// Serve `ckp-panel://<sessão>/<path relativo>` — só arquivos dentro da
  /// pasta do `.panel` (caminho canônico, sem `..` escapando).
  Future<CustomSchemeResponse?> _serveLocal(
    InAppWebViewController web,
    WebResourceRequest request,
  ) async {
    final uri = request.url;
    if (uri.scheme != 'ckp-panel') return null;
    final rel = Uri.decodeComponent(uri.path).replaceFirst(RegExp(r'^/+'), '');
    if (rel.isEmpty) return null;
    final root = Directory(_docDir).absolute.path;
    final file = File('$root/$rel').absolute;
    final canonical = file.path;
    if (!canonical.startsWith('$root${Platform.pathSeparator}')) return null;
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    return CustomSchemeResponse(
      data: bytes,
      contentType: _mimeOf(canonical),
      contentEncoding: 'utf-8',
    );
  }

  static String _mimeOf(String path) {
    final ext = path.split('.').last.toLowerCase();
    return switch (ext) {
      'html' || 'htm' => 'text/html',
      'js' || 'mjs' => 'text/javascript',
      'css' => 'text/css',
      'json' => 'application/json',
      'svg' => 'image/svg+xml',
      'png' => 'image/png',
      'jpg' || 'jpeg' => 'image/jpeg',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'ico' => 'image/x-icon',
      'woff' => 'font/woff',
      'woff2' => 'font/woff2',
      'txt' || 'md' || 'csv' => 'text/plain',
      _ => 'application/octet-stream',
    };
  }

  Future<Object?> _handleCall(List<dynamic> args) async {
    final line = args.isEmpty ? '' : args.first.toString();
    return widget.onCall(line, _cwd);
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.cockpit.panelView;
    if (!_inline) {
      return _Unavailable(
        message: tr.unavailable,
        openInBrowser: tr.openInBrowser,
        openAsHtml: tr.openAsHtml,
        path: widget.session.path,
        onOpenAsHtml: widget.session.toggleRawSource,
      );
    }
    final bridge = _bridge;
    final doc = _doc;
    if (bridge == null || doc == null) {
      return ColoredBox(color: context.colors.panel);
    }
    return UnzoomedNativeView(
      builder: (context, contentZoom) => InAppWebView(
        key: ValueKey('panel:${widget.session.id}'),
        initialData: InAppWebViewInitialData(
          data: doc.body,
          baseUrl: WebUri(_baseUrl),
          mimeType: 'text/html',
          encoding: 'utf-8',
        ),
        initialUserScripts: UnmodifiableListView<UserScript>([
          UserScript(
            source: bridge,
            injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
          ),
        ]),
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          resourceCustomSchemes: ['ckp-panel'],
          // Playground de desenvolvedor: o inspetor do Safari/Edge ajuda a
          // depurar o painel.
          isInspectable: true,
          transparentBackground: true,
          pageZoom: contentZoom,
        ),
        onWebViewCreated: (web) {
          _web = web;
          web.addJavaScriptHandler(
            handlerName: 'cockpit',
            callback: _handleCall,
          );
        },
        onLoadStop: (web, _) {
          _loaded = true;
          final vars = _themeVars(context);
          _pushedTheme = vars;
          unawaited(_pushTheme(vars));
        },
        onLoadResourceWithCustomScheme: _serveLocal,
        // Links externos abrem no browser do SO — a aba não navega pra fora.
        shouldOverrideUrlLoading: (web, action) async {
          final url = action.request.url;
          if (url == null ||
              url.scheme == 'about' ||
              url.scheme == 'data' ||
              url.scheme == 'ckp-panel') {
            return NavigationActionPolicy.ALLOW;
          }
          if (url.scheme == 'http' || url.scheme == 'https') {
            await launcher.launchUrl(url);
          }
          return NavigationActionPolicy.CANCEL;
        },
      ),
    );
  }
}

/// Linux (sem webview inline): explica e oferece o navegador do SO ou o HTML.
class _Unavailable extends StatelessWidget {
  const _Unavailable({
    required this.message,
    required this.openInBrowser,
    required this.openAsHtml,
    required this.path,
    required this.onOpenAsHtml,
  });

  final String message;
  final String openInBrowser;
  final String openAsHtml;
  final String path;
  final VoidCallback onOpenAsHtml;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: context.colors.panel,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                message,
                textAlign: TextAlign.center,
                style: context.typo.body.copyWith(color: context.colors.text3),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  OutlineButton(
                    onPressed: () =>
                        unawaited(launcher.launchUrl(Uri.file(path))),
                    child: Text(openInBrowser),
                  ),
                  const SizedBox(width: 8),
                  OutlineButton(
                    onPressed: onOpenAsHtml,
                    child: Text(openAsHtml),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
