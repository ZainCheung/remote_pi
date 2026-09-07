/// Um "documento especial" do Cockpit que a aba Gallery sabe criar na raiz do
/// workspace: extensão própria + conteúdo inicial que já abre na tab certa
/// (`.dbq` → editor SQL, `.kanban` → quadro, `.ckp` → layout, `.http` →
/// cliente HTTP). Título/descrição são i18n na UI; aqui só o que é dado.
enum GalleryTemplate {
  dbQuery(
    baseName: 'query',
    extension: 'dbq',
    iconAsset: 'assets/file_icons/database.svg',
    content: '-- limit: 100\nSELECT 1;\n',
  ),
  kanban(
    baseName: 'board',
    extension: 'kanban',
    iconAsset: 'assets/file_icons/todo.svg',
    content:
        '---\n'
        'columns: [Backlog, Doing, Done]\n'
        'labels: {bug: red, feature: blue}\n'
        '---\n'
        '\n'
        '## Backlog\n'
        '\n'
        '- [ ] First card <!-- id: k1 labels: feature -->\n'
        '\n'
        '## Doing\n'
        '\n'
        '## Done\n',
  ),
  layout(
    baseName: 'dev',
    extension: 'ckp',
    iconAsset: 'assets/branding/cockpit_logo.png',
    content:
        '# Pane layout — apply with right-click → Open layout,\n'
        '# or `cockpit orchestrate dev.ckp` from a tab.\n'
        '# autorun: worktree   # apply automatically on new worktrees\n'
        'panes:\n'
        '  - name: Shell\n'
        '    cwd: .\n'
        '  - name: Agent\n'
        '    cwd: .\n'
        '    split: right\n'
        '    command: claude\n',
  ),
  httpRequest(
    baseName: 'requests',
    extension: 'http',
    iconAsset: 'assets/file_icons/http.svg',
    content:
        '### Ping\n'
        'GET https://httpbin.org/get\n'
        'Accept: application/json\n',
  );

  const GalleryTemplate({
    required this.baseName,
    required this.extension,
    required this.iconAsset,
    required this.content,
  });

  /// Nome sugerido sem extensão (`dev` → `dev.ckp`, `dev-2.ckp` se já existe).
  final String baseName;
  final String extension;

  /// Asset colorido do card (SVG do tema de ícones ou o logo do Cockpit).
  final String iconAsset;

  /// Conteúdo inicial do arquivo.
  final String content;

  String get fileName => '$baseName.$extension';

  /// Primeiro nome livre dado o conjunto de [taken] (basenames da raiz,
  /// comparados sem case): `dev.ckp`, `dev-2.ckp`, `dev-3.ckp`…
  String uniqueFileName(Iterable<String> taken) {
    final lower = taken.map((n) => n.toLowerCase()).toSet();
    if (!lower.contains(fileName.toLowerCase())) return fileName;
    for (var i = 2; ; i++) {
      final candidate = '$baseName-$i.$extension';
      if (!lower.contains(candidate.toLowerCase())) return candidate;
    }
  }
}
