import 'dart:async';

import 'package:cockpit/app/cockpit/domain/entities/notebook_document.dart';
import 'package:cockpit/app/cockpit/ui/session/notebook_session.dart';
import 'package:cockpit/app/cockpit/ui/viewmodels/cockpit_viewmodel.dart';
import 'package:cockpit/app/cockpit/ui/widgets/agent_markdown.dart';
import 'package:cockpit/app/cockpit/ui/widgets/code_editor.dart';
import 'package:cockpit/app/cockpit/ui/widgets/confirm_dialog.dart';
import 'package:cockpit/app/core/domain/result.dart';
import 'package:cockpit/app/core/ui/file_operation_error_message.dart';
import 'package:cockpit/app/core/ui/themes/themes.dart';
import 'package:cockpit/app/core/ui/widgets/app_menu.dart';
import 'package:cockpit/app/core/ui/widgets/app_tooltip.dart';
import 'package:cockpit/app/core/ui/widgets/code_editing_controller.dart';
import 'package:cockpit/app/core/ui/widgets/hover_tap.dart';
import 'package:cockpit/app/core/utils/path_utils.dart';
import 'package:cockpit/i18n/strings.g.dart';
import 'package:flutter/material.dart'
    as material
    show TextField, InputDecoration, InputBorder;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_modular/flutter_modular.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

/// Tab de um caderno `nome.notebook/` (plano 62, passo 4). Protótipo visual:
/// três colunas — notas (busca, ordenadas por `updated`) | nota ativa (preview
/// markdown, com edição do fonte) | tags com contagem (clicar filtra).
///
/// Lê a pasta pelo VM (`listChildren` + `readTextAt`), então funciona local e
/// remoto. Estado de leitura mora aqui; a sessão só carrega a identidade.
class NotebookView extends StatefulWidget {
  const NotebookView({
    super.key,
    required this.session,
    required this.active,
    required this.focused,
  });

  final NotebookSession session;
  final bool active;
  final bool focused;

  @override
  State<NotebookView> createState() => _NotebookViewState();
}

class _NotebookViewState extends State<NotebookView> {
  List<NotebookNote> _notes = const [];
  bool _loading = true;
  String? _selectedPath;
  final Set<String> _collapsed = <String>{};
  final TextEditingController _tagInput = TextEditingController();
  final TextEditingController _titleCtrl = TextEditingController();
  final FocusNode _titleFocus = FocusNode(debugLabel: 'notebookTitle');
  String _query = '';
  bool _editing = false;
  bool _dirty = false;
  bool _saving = false;
  late final CodeEditingController _editor = CodeEditingController(
    text: '',
    language: 'markdown',
  );
  final FocusNode _editorFocus = FocusNode(debugLabel: 'notebookEditor');
  final TextEditingController _search = TextEditingController();
  int _seenReload = 0;
  StreamSubscription<void>? _watch;
  Timer? _watchDebounce;

  CockpitViewModel get _vm => context.read<CockpitViewModel>();

  @override
  void initState() {
    super.initState();
    _seenReload = widget.session.reloadTick;
    widget.session.addListener(_onSession);
    _editor.addListener(_onEdited);
    _load();
    // Nota escrita pelo agente (ou pelo Obsidian) aparece sozinha.
    _watch = _vm.watchFolder(widget.session.path).listen((_) {
      _watchDebounce?.cancel();
      _watchDebounce = Timer(const Duration(milliseconds: 200), _load);
    });
  }

  @override
  void dispose() {
    _watchDebounce?.cancel();
    _watch?.cancel();
    widget.session.removeListener(_onSession);
    _editor
      ..removeListener(_onEdited)
      ..dispose();
    _editorFocus.dispose();
    _search.dispose();
    _tagInput.dispose();
    _titleCtrl.dispose();
    _titleFocus.dispose();
    super.dispose();
  }

  void _onSession() {
    if (widget.session.reloadTick != _seenReload) {
      _seenReload = widget.session.reloadTick;
      _load();
    }
  }

  void _onEdited() {
    final sel = _selected;
    final dirty = sel != null && _editor.text != sel.raw;
    if (dirty != _dirty) setState(() => _dirty = dirty);
  }

  NotebookNote? get _selected {
    for (final n in _notes) {
      if (n.path == _selectedPath) return n;
    }
    return null;
  }

  Future<void> _load() async {
    final vm = _vm;
    final children = await vm.listChildren(widget.session.path);
    final notes = <NotebookNote>[];
    for (final c in children) {
      if (c.isDirectory || !c.name.toLowerCase().endsWith('.md')) continue;
      final raw = await vm.readTextAt(c.path);
      if (raw == null) continue;
      notes.add(NotebookNote.parse(c.path, raw));
    }
    notes.sort((a, b) {
      final da = a.sortDate, db = b.sortDate;
      if (da == null && db == null) return a.title.compareTo(b.title);
      if (da == null) return 1;
      if (db == null) return -1;
      return db.compareTo(da);
    });
    if (!mounted) return;
    setState(() {
      _notes = notes;
      _loading = false;
      if (_selected == null && notes.isNotEmpty) {
        _selectedPath = notes.first.path;
      }
      // Edição em curso não é sobrescrita por um reload do disco.
      if (!(_editing && _dirty)) _syncEditor();
    });
  }

  void _syncEditor() {
    final sel = _selected;
    _editor.text = sel?.raw ?? '';
    _dirty = false;
    // O título é sempre um campo; só realinha com o disco quando o usuário
    // não está digitando nele.
    if (!_titleFocus.hasFocus) _titleCtrl.text = sel?.title ?? '';
  }

  Future<void> _select(NotebookNote n) async {
    if (n.path == _selectedPath) return;
    if (_editing && _dirty) {
      final tr = context.t.cockpit.notebook;
      final discard = await showConfirmDialog(
        context,
        title: tr.unsavedTitle,
        message: tr.unsavedMessage(name: _selected?.title ?? ''),
        confirmLabel: tr.discard,
        danger: true,
      );
      if (!discard || !mounted) return;
    }
    setState(() {
      _selectedPath = n.path;
      _editing = false;
      _syncEditor();
    });
  }

  List<NotebookNote> get _visible {
    final q = _query.trim().toLowerCase();
    return _notes.where((n) {
      if (q.isEmpty) return true;
      return n.title.toLowerCase().contains(q) ||
          n.body.toLowerCase().contains(q) ||
          n.tags.any((t) => t.contains(q));
    }).toList();
  }

  /// Agrupa as notas visíveis por tag (uma nota com N tags aparece em N
  /// grupos, como os smart folders do Apple Notes). Sem tag vem primeiro;
  /// depois `agent`; o resto por ordem alfabética.
  List<(String, List<NotebookNote>)> get _groups {
    final m = <String, List<NotebookNote>>{};
    for (final n in _visible) {
      for (final t in n.tags) {
        (m[t] ??= []).add(n);
      }
    }
    final keys = m.keys.toList()
      ..sort((a, b) {
        int rank(String t) => t == kUntagged ? 0 : (t == kAgentTag ? 1 : 2);
        final r = rank(a).compareTo(rank(b));
        return r != 0 ? r : a.compareTo(b);
      });
    return [for (final k in keys) (k, m[k]!)];
  }

  Future<void> _setTags(List<String> tags) async {
    final sel = _selected;
    if (sel == null || _saving) return;
    final base = _editing ? _editor.text : sel.raw;
    setState(() => _saving = true);
    final content = NotebookNote.touchUpdated(
      NotebookNote.setTags(base, tags),
      DateTime.now(),
    );
    final ok = await _vm.writeTextAt(sel.path, content);
    if (!mounted) return;
    setState(() => _saving = false);
    if (!ok) {
      await showConfirmDialog(
        context,
        title: context.t.cockpit.notebook.saveFailed,
        message: sel.fileName,
        confirmLabel: context.t.common.ok,
      );
      return;
    }
    await _load();
  }

  Future<void> _noteMenu(NotebookNote n, Offset position) async {
    final tr = context.t.cockpit.notebook;
    final choice = await showAppMenu<String>(
      context,
      globalPosition: position,
      items: [
        AppMenuItem(
          value: 'delete',
          label: tr.deleteNote,
          icon: Icons.delete_outline,
          danger: true,
        ),
      ],
    );
    if (!mounted || choice != 'delete') return;
    final ok = await showConfirmDialog(
      context,
      title: tr.deleteNote,
      message: tr.deleteConfirm(name: n.title),
      confirmLabel: context.t.common.delete,
      danger: true,
    );
    if (!ok || !mounted) return;
    final r = await _vm.deletePath(n.path);
    if (!mounted) return;
    if (r case Failure(:final error)) {
      await showConfirmDialog(
        context,
        title: tr.deleteNote,
        message: fileOperationErrorMessage(context, error),
        confirmLabel: context.t.common.ok,
      );
      return;
    }
    if (_selectedPath == n.path) {
      _selectedPath = null;
      _editing = false;
    }
    await _load();
  }

  /// Foca o título com tudo selecionado (nota nova: digita por cima de
  /// "Untitled").
  void _focusTitle() {
    final sel = _selected;
    if (sel == null) return;
    _titleCtrl.text = sel.title;
    _titleCtrl.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _titleCtrl.text.length,
    );
    _titleFocus.requestFocus();
  }

  /// Enter ou perder o foco grava o título (uma linha; Enter não quebra).
  Future<void> _commitTitle() async {
    final sel = _selected;
    final title = _titleCtrl.text.trim();
    if (sel == null || _saving) return;
    if (title.isEmpty || title == sel.title) {
      _titleCtrl.text = sel.title;
      return;
    }
    final base = _editing ? _editor.text : sel.raw;
    setState(() => _saving = true);
    final content = NotebookNote.touchUpdated(
      NotebookNote.setTitle(base, title),
      DateTime.now(),
    );
    final ok = await _vm.writeTextAt(sel.path, content);
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) await _load();
  }

  void _addTag(String raw) {
    final sel = _selected;
    final t = raw.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '-');
    if (sel == null || t.isEmpty) return;
    _tagInput.clear();
    final tags = sel.tags.where((x) => x != kUntagged).toList();
    if (tags.contains(t)) return;
    _setTags([...tags, t]);
  }

  void _removeTag(String t) {
    final sel = _selected;
    if (sel == null) return;
    _setTags(sel.tags.where((x) => x != t && x != kUntagged).toList());
  }

  Future<void> _save() async {
    final sel = _selected;
    if (sel == null || _saving) return;
    setState(() => _saving = true);
    final content = NotebookNote.touchUpdated(_editor.text, DateTime.now());
    final ok = await _vm.writeTextAt(sel.path, content);
    if (!mounted) return;
    setState(() => _saving = false);
    if (!ok) {
      await showConfirmDialog(
        context,
        title: context.t.cockpit.notebook.saveFailed,
        message: sel.fileName,
        confirmLabel: context.t.common.ok,
      );
      return;
    }
    setState(() => _editing = false);
    await _load();
  }

  /// Cria "Untitled" direto (sem diálogo), seleciona e já abre o título pra
  /// edição — o usuário renomeia ali mesmo.
  Future<void> _newNote() async {
    final title = context.t.cockpit.notebook.untitled;
    final now = DateTime.now();
    var path = joinPath(
      widget.session.path,
      NotebookNote.fileNameFor(title, now),
    );
    var i = 2;
    final taken = _notes.map((n) => n.path).toSet();
    while (taken.contains(path)) {
      path = joinPath(
        widget.session.path,
        NotebookNote.fileNameFor('$title $i', now),
      );
      i++;
    }
    final ok = await _vm.writeTextAt(
      path,
      NotebookNote.template(title: title, tags: const [], now: now),
    );
    if (!mounted) return;
    if (!ok) {
      await showConfirmDialog(
        context,
        title: context.t.cockpit.notebook.createFailed,
        message: path,
        confirmLabel: context.t.common.ok,
      );
      return;
    }
    _selectedPath = path;
    _editing = false;
    await _load();
    if (mounted) _focusTitle();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, meta: true): _save,
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): _save,
      },
      child: Container(
        color: colors.bg,
        child: Column(
          children: [
            _Header(
              title: widget.session.title,
              count: _notes.length,
              search: _search,
              onQuery: (q) => setState(() => _query = q),
              onNew: _newNote,
              onReload: _load,
            ),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: 210,
                    child: _NotesColumn(
                      groups: _groups,
                      loading: _loading,
                      hasAny: _notes.isNotEmpty,
                      selectedPath: _selectedPath,
                      collapsed: _collapsed,
                      onToggleGroup: (t) => setState(() {
                        if (!_collapsed.remove(t)) _collapsed.add(t);
                      }),
                      onSelect: _select,
                      onMenu: _noteMenu,
                    ),
                  ),
                  VerticalDivider(width: 1, color: colors.border),
                  Expanded(
                    child: _NoteColumn(
                      note: _selected,
                      editing: _editing,
                      dirty: _dirty,
                      saving: _saving,
                      editor: _editor,
                      editorFocus: _editorFocus,
                      tagInput: _tagInput,
                      titleCtrl: _titleCtrl,
                      titleFocus: _titleFocus,
                      onCommitTitle: _commitTitle,
                      onToggleEdit: () => setState(() {
                        _editing = !_editing;
                        if (_editing) _editorFocus.requestFocus();
                      }),
                      onSave: _save,
                      onAddTag: _addTag,
                      onRemoveTag: _removeTag,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _Header extends StatelessWidget {
  const _Header({
    required this.title,
    required this.count,
    required this.search,
    required this.onQuery,
    required this.onNew,
    required this.onReload,
  });

  final String title;
  final int count;
  final TextEditingController search;
  final ValueChanged<String> onQuery;
  final VoidCallback onNew;
  final VoidCallback onReload;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final tr = context.t.cockpit.notebook;
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: Row(
        children: [
          Icon(Icons.menu_book_outlined, size: 16, color: colors.text2),
          const SizedBox(width: 8),
          Text(
            title,
            style: context.typo.label.copyWith(
              color: colors.text,
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            tr.noteCount(count: count),
            style: context.typo.label.copyWith(color: colors.text3),
          ),
          const Spacer(),
          SizedBox(
            width: 220,
            height: 28,
            child: TextField(
              controller: search,
              onChanged: onQuery,
              placeholder: Text(tr.searchPlaceholder),
              features: const [
                InputFeature.leading(Icon(Icons.search, size: 14)),
              ],
              style: context.typo.label.copyWith(color: colors.text),
              border: Border.all(color: colors.border),
              borderRadius: BorderRadius.circular(6),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            ),
          ),
          const SizedBox(width: 8),
          _IconAction(icon: Icons.refresh, tooltip: tr.reload, onTap: onReload),
          const SizedBox(width: 4),
          HoverTap(
            color: colors.panel2,
            borderRadius: BorderRadius.circular(6),
            onTap: onNew,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(
                children: [
                  Icon(Icons.add, size: 14, color: colors.text),
                  const SizedBox(width: 6),
                  Text(
                    tr.newNote,
                    style: context.typo.label.copyWith(color: colors.text),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _IconAction extends StatelessWidget {
  const _IconAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.selected = false,
  });
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return AppTooltip(
      message: tooltip,
      child: HoverTap(
        color: selected ? colors.panel2 : Colors.transparent,
        borderRadius: BorderRadius.circular(5),
        onTap: onTap,
        child: SizedBox(
          width: 28,
          height: 28,
          child: Icon(
            icon,
            size: 15,
            color: selected ? colors.text : colors.text3,
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _NotesColumn extends StatelessWidget {
  const _NotesColumn({
    required this.groups,
    required this.loading,
    required this.hasAny,
    required this.selectedPath,
    required this.collapsed,
    required this.onToggleGroup,
    required this.onSelect,
    required this.onMenu,
  });

  final List<(String, List<NotebookNote>)> groups;
  final bool loading;
  final bool hasAny;
  final String? selectedPath;
  final Set<String> collapsed;
  final ValueChanged<String> onToggleGroup;
  final ValueChanged<NotebookNote> onSelect;
  final void Function(NotebookNote, Offset) onMenu;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final tr = context.t.cockpit.notebook;
    if (loading) return const Center(child: CircularProgressIndicator());
    if (groups.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(14),
        child: Text(
          hasAny ? tr.noMatch : tr.empty,
          style: context.typo.label.copyWith(color: colors.text3),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 4),
      children: [
        for (final (tag, notes) in groups) ...[
          HoverTap(
            key: ValueKey('group-$tag'),
            onTap: () => onToggleGroup(tag),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 10, 4),
              child: Row(
                children: [
                  Icon(
                    collapsed.contains(tag)
                        ? Icons.chevron_right
                        : Icons.expand_more,
                    size: 14,
                    color: colors.text3,
                  ),
                  const SizedBox(width: 2),
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _tagColor(tag, colors),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      tag == kUntagged ? tr.untagged : tag,
                      overflow: TextOverflow.ellipsis,
                      style: context.typo.label.copyWith(
                        fontSize: 10.5,
                        letterSpacing: 0.6,
                        fontWeight: FontWeight.w600,
                        color: colors.text2,
                      ),
                    ),
                  ),
                  Text(
                    '${notes.length}',
                    style: context.typo.label.copyWith(
                      fontSize: 10,
                      color: colors.text3,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (!collapsed.contains(tag))
            for (final n in notes)
              _NoteRow(
                key: ValueKey('note-$tag-${n.path}'),
                note: n,
                selected: n.path == selectedPath,
                onTap: () => onSelect(n),
                onMenu: (pos) => onMenu(n, pos),
              ),
        ],
      ],
    );
  }
}

class _NoteRow extends StatelessWidget {
  const _NoteRow({
    super.key,
    required this.note,
    required this.selected,
    required this.onTap,
    required this.onMenu,
  });
  final NotebookNote note;
  final bool selected;
  final VoidCallback onTap;
  final ValueChanged<Offset> onMenu;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final n = note;
    return GestureDetector(
      onSecondaryTapUp: (d) => onMenu(d.globalPosition),
      child: HoverTap(
        color: selected ? colors.panel2 : Colors.transparent,
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(22, 5, 10, 5),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                width: 2,
                color: selected ? colors.accent : Colors.transparent,
              ),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (n.fromAgent) ...[
                    Icon(Icons.auto_awesome, size: 10, color: colors.accent),
                    const SizedBox(width: 4),
                  ],
                  Expanded(
                    child: Text(
                      n.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.typo.label.copyWith(
                        fontSize: 12,
                        color: colors.text,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 1),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _excerpt(n.body),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.typo.label.copyWith(
                        fontSize: 10.5,
                        color: colors.text3,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _excerpt(String body) {
    final line = body
        .split('\n')
        .map((l) => l.trim())
        .firstWhere(
          (l) => l.isNotEmpty && !l.startsWith('#'),
          orElse: () => '',
        );
    return line.replaceAll(RegExp(r'[*_`>#\[\]]'), '');
  }
}

// ---------------------------------------------------------------------------

class _NoteColumn extends StatelessWidget {
  const _NoteColumn({
    required this.note,
    required this.editing,
    required this.dirty,
    required this.saving,
    required this.editor,
    required this.editorFocus,
    required this.tagInput,
    required this.titleCtrl,
    required this.titleFocus,
    required this.onCommitTitle,
    required this.onToggleEdit,
    required this.onSave,
    required this.onAddTag,
    required this.onRemoveTag,
  });

  final NotebookNote? note;
  final bool editing;
  final bool dirty;
  final bool saving;
  final CodeEditingController editor;
  final FocusNode editorFocus;
  final TextEditingController tagInput;
  final TextEditingController titleCtrl;
  final FocusNode titleFocus;
  final VoidCallback onCommitTitle;
  final VoidCallback onToggleEdit;
  final VoidCallback onSave;
  final ValueChanged<String> onAddTag;
  final ValueChanged<String> onRemoveTag;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final tr = context.t.cockpit.notebook;
    final n = note;
    if (n == null) {
      return Center(
        child: Text(
          tr.selectNote,
          style: context.typo.label.copyWith(color: colors.text3),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Cabeçalho da nota: título, tags, ações.
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Focus(
                      onFocusChange: (has) {
                        if (!has) onCommitTitle();
                      },
                      // Sempre um campo (sem alternar texto ↔ campo). Material
                      // sem decoração: o TextField do shadcn sempre desenha
                      // anel de foco + fundo. Uma linha: Enter grava, não
                      // quebra; título longo rola horizontalmente.
                      child: material.TextField(
                        controller: titleCtrl,
                        focusNode: titleFocus,
                        maxLines: 1,
                        cursorColor: colors.text,
                        style: context.typo.label.copyWith(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: colors.text,
                        ),
                        decoration: const material.InputDecoration(
                          isCollapsed: true,
                          border: material.InputBorder.none,
                          contentPadding: EdgeInsets.zero,
                        ),
                        onSubmitted: (_) => onCommitTitle(),
                      ),
                    ),
                  ],
                ),
              ),
              if (editing && dirty)
                HoverTap(
                  color: colors.accent,
                  borderRadius: BorderRadius.circular(6),
                  onTap: saving ? () {} : onSave,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    child: Text(
                      tr.save,
                      style: context.typo.label.copyWith(
                        color: colors.accentText,
                      ),
                    ),
                  ),
                ),
              const SizedBox(width: 4),
              _IconAction(
                icon: editing ? Icons.visibility_outlined : Icons.edit_outlined,
                tooltip: editing ? tr.preview : tr.edit,
                selected: editing,
                onTap: onToggleEdit,
              ),
            ],
          ),
        ),
        Divider(height: 1, color: colors.border),
        Expanded(
          child: editing
              ? Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
                  child: CodeEditor(controller: editor, focusNode: editorFocus),
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
                  child: AgentMarkdown(n.body),
                ),
        ),
        // Rodapé: tags da nota (múltiplas), com remover e adicionar inline.
        Container(
          padding: const EdgeInsets.fromLTRB(20, 8, 12, 8),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: colors.border)),
          ),
          child: Row(
            children: [
              Icon(Icons.sell_outlined, size: 13, color: colors.text3),
              const SizedBox(width: 8),
              Expanded(
                child: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    for (final t in n.tags.where((t) => t != kUntagged))
                      _TagChip(t, onRemove: () => onRemoveTag(t)),
                    SizedBox(
                      width: 140,
                      height: 24,
                      child: TextField(
                        controller: tagInput,
                        placeholder: Text(tr.addTag),
                        style: context.typo.label.copyWith(
                          fontSize: 11,
                          color: colors.text,
                        ),
                        border: Border.all(color: Colors.transparent),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        onSubmitted: onAddTag,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------

class _TagChip extends StatelessWidget {
  const _TagChip(this.tag, {this.onRemove});
  final String tag;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final c = _tagColor(tag, context.colors);
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 2, 6, 2),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(tag, style: context.typo.label.copyWith(fontSize: 11, color: c)),
          if (onRemove != null) ...[
            const SizedBox(width: 4),
            HoverTap(
              borderRadius: BorderRadius.circular(8),
              onTap: onRemove!,
              child: Icon(Icons.close, size: 11, color: c),
            ),
          ],
        ],
      ),
    );
  }
}

/// Cor estável por tag (hash do nome sobre uma paleta de tokens do tema).
Color _tagColor(String tag, AppColors colors) {
  if (tag == kUntagged) return colors.text3;
  if (tag == kAgentTag) return colors.accent;
  // Mesma paleta do kanban (tokens do tema, não hex).
  final palette = [
    colors.gitConflict,
    colors.edited,
    colors.error,
    colors.online,
    colors.warn,
    colors.gitUntracked,
  ];
  var h = 0;
  for (final u in tag.codeUnits) {
    h = (h * 31 + u) & 0x7fffffff;
  }
  return palette[h % palette.length];
}
