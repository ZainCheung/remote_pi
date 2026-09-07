import 'package:cockpit/app/cockpit/domain/entities/notebook_document.dart';
import 'package:cockpit/app/cockpit/ui/session/notebook_session.dart';
import 'package:cockpit/app/cockpit/ui/viewmodels/cockpit_viewmodel.dart';
import 'package:cockpit/app/cockpit/ui/widgets/agent_markdown.dart';
import 'package:cockpit/app/cockpit/ui/widgets/code_editor.dart';
import 'package:cockpit/app/cockpit/ui/widgets/confirm_dialog.dart';
import 'package:cockpit/app/core/ui/themes/themes.dart';
import 'package:cockpit/app/core/ui/widgets/app_tooltip.dart';
import 'package:cockpit/app/core/ui/widgets/code_editing_controller.dart';
import 'package:cockpit/app/core/ui/widgets/hover_tap.dart';
import 'package:cockpit/app/core/utils/path_utils.dart';
import 'package:cockpit/i18n/strings.g.dart';
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
  String? _tagFilter;
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

  CockpitViewModel get _vm => context.read<CockpitViewModel>();

  @override
  void initState() {
    super.initState();
    _seenReload = widget.session.reloadTick;
    widget.session.addListener(_onSession);
    _editor.addListener(_onEdited);
    _load();
  }

  @override
  void dispose() {
    widget.session.removeListener(_onSession);
    _editor
      ..removeListener(_onEdited)
      ..dispose();
    _editorFocus.dispose();
    _search.dispose();
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
      _syncEditor();
    });
  }

  void _syncEditor() {
    final sel = _selected;
    _editor.text = sel?.raw ?? '';
    _dirty = false;
  }

  void _select(NotebookNote n) {
    if (n.path == _selectedPath) return;
    setState(() {
      _selectedPath = n.path;
      _editing = false;
      _syncEditor();
    });
  }

  List<NotebookNote> get _visible {
    final q = _query.trim().toLowerCase();
    return _notes.where((n) {
      if (_tagFilter != null && !n.tags.contains(_tagFilter)) return false;
      if (q.isEmpty) return true;
      return n.title.toLowerCase().contains(q) ||
          n.body.toLowerCase().contains(q) ||
          n.tags.any((t) => t.contains(q));
    }).toList();
  }

  Map<String, int> get _tagCounts {
    final m = <String, int>{};
    for (final n in _notes) {
      for (final t in n.tags) {
        m[t] = (m[t] ?? 0) + 1;
      }
    }
    final entries = m.entries.toList()
      ..sort((a, b) {
        final c = b.value.compareTo(a.value);
        return c != 0 ? c : a.key.compareTo(b.key);
      });
    return {for (final e in entries) e.key: e.value};
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

  Future<void> _newNote() async {
    final tr = context.t.cockpit.notebook;
    final ctrl = TextEditingController();
    final title = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr.newNoteTitle),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: TextField(
            controller: ctrl,
            autofocus: true,
            placeholder: Text(tr.titlePlaceholder),
            onSubmitted: (v) => Navigator.of(ctx).pop(v),
          ),
        ),
        actions: [
          GhostButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(ctx.t.common.cancel),
          ),
          PrimaryButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text),
            child: Text(ctx.t.common.create),
          ),
        ],
      ),
    );
    if (!mounted || title == null || title.trim().isEmpty) return;
    final now = DateTime.now();
    final tags = _tagFilter == null || _tagFilter == kUntagged
        ? const <String>[]
        : [_tagFilter!];
    final path = joinPath(
      widget.session.path,
      NotebookNote.fileNameFor(title.trim(), now),
    );
    final ok = await _vm.writeTextAt(
      path,
      NotebookNote.template(title: title.trim(), tags: tags, now: now),
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
    _editing = true;
    await _load();
    if (mounted) _editorFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final tr = context.t.cockpit.notebook;
    return Container(
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
                  width: 240,
                  child: _NotesColumn(
                    notes: _visible,
                    loading: _loading,
                    hasAny: _notes.isNotEmpty,
                    selectedPath: _selectedPath,
                    onSelect: _select,
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
                    onToggleEdit: () => setState(() {
                      _editing = !_editing;
                      if (_editing) _editorFocus.requestFocus();
                    }),
                    onSave: _save,
                    onTagTap: (t) => setState(() => _tagFilter = t),
                  ),
                ),
                VerticalDivider(width: 1, color: colors.border),
                SizedBox(
                  width: 180,
                  child: _TagsColumn(
                    counts: _tagCounts,
                    total: _notes.length,
                    selected: _tagFilter,
                    onSelect: (t) => setState(() => _tagFilter = t),
                    allLabel: tr.allTags,
                  ),
                ),
              ],
            ),
          ),
        ],
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
    required this.notes,
    required this.loading,
    required this.hasAny,
    required this.selectedPath,
    required this.onSelect,
  });

  final List<NotebookNote> notes;
  final bool loading;
  final bool hasAny;
  final String? selectedPath;
  final ValueChanged<NotebookNote> onSelect;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final tr = context.t.cockpit.notebook;
    if (loading) return const Center(child: CircularProgressIndicator());
    if (notes.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          hasAny ? tr.noMatch : tr.empty,
          style: context.typo.label.copyWith(color: colors.text3),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemCount: notes.length,
      itemBuilder: (context, i) {
        final n = notes[i];
        final selected = n.path == selectedPath;
        return HoverTap(
          key: ValueKey('note-${n.path}'),
          color: selected ? colors.panel2 : Colors.transparent,
          onTap: () => onSelect(n),
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
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
                      Icon(Icons.auto_awesome, size: 11, color: colors.accent),
                      const SizedBox(width: 5),
                    ],
                    Expanded(
                      child: Text(
                        n.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.typo.label.copyWith(
                          color: colors.text,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  _excerpt(n.body),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: context.typo.label.copyWith(
                    fontSize: 11,
                    color: colors.text3,
                  ),
                ),
                const SizedBox(height: 5),
                Row(
                  children: [
                    Expanded(
                      child: Wrap(
                        spacing: 4,
                        runSpacing: 2,
                        children: [
                          for (final t in n.tags.take(3))
                            _TagChip(t, small: true),
                        ],
                      ),
                    ),
                    if (n.sortDate != null)
                      Text(
                        _shortDate(n.sortDate!),
                        style: context.typo.label.copyWith(
                          fontSize: 10,
                          color: colors.text3,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
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

  static String _shortDate(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    final now = DateTime.now();
    final sameDay =
        d.year == now.year && d.month == now.month && d.day == now.day;
    return sameDay
        ? '${two(d.hour)}:${two(d.minute)}'
        : '${two(d.day)}/${two(d.month)}';
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
    required this.onToggleEdit,
    required this.onSave,
    required this.onTagTap,
  });

  final NotebookNote? note;
  final bool editing;
  final bool dirty;
  final bool saving;
  final CodeEditingController editor;
  final FocusNode editorFocus;
  final VoidCallback onToggleEdit;
  final VoidCallback onSave;
  final ValueChanged<String> onTagTap;

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
                    Text(
                      n.title,
                      style: context.typo.label.copyWith(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: colors.text,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        for (final t in n.tags)
                          HoverTap(
                            borderRadius: BorderRadius.circular(10),
                            onTap: () => onTagTap(t),
                            child: _TagChip(t),
                          ),
                        if (n.updated != null)
                          Padding(
                            padding: const EdgeInsets.only(left: 4, top: 2),
                            child: Text(
                              _fullDate(n.updated!),
                              style: context.typo.label.copyWith(
                                fontSize: 11,
                                color: colors.text3,
                              ),
                            ),
                          ),
                      ],
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
      ],
    );
  }

  static String _fullDate(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }
}

// ---------------------------------------------------------------------------

class _TagsColumn extends StatelessWidget {
  const _TagsColumn({
    required this.counts,
    required this.total,
    required this.selected,
    required this.onSelect,
    required this.allLabel,
  });

  final Map<String, int> counts;
  final int total;
  final String? selected;
  final ValueChanged<String?> onSelect;
  final String allLabel;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final tr = context.t.cockpit.notebook;
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 4, 12, 6),
          child: Text(
            tr.tags.toUpperCase(),
            style: context.typo.label.copyWith(
              fontSize: 10,
              letterSpacing: 1.1,
              color: colors.text3,
            ),
          ),
        ),
        _TagRow(
          label: allLabel,
          count: total,
          selected: selected == null,
          onTap: () => onSelect(null),
        ),
        for (final e in counts.entries)
          _TagRow(
            key: ValueKey('tag-${e.key}'),
            label: e.key,
            count: e.value,
            selected: selected == e.key,
            color: _tagColor(e.key, colors),
            onTap: () => onSelect(selected == e.key ? null : e.key),
          ),
      ],
    );
  }
}

class _TagRow extends StatelessWidget {
  const _TagRow({
    super.key,
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
    this.color,
  });
  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return HoverTap(
      color: selected ? colors.panel2 : Colors.transparent,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        child: Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color ?? colors.text3,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: context.typo.label.copyWith(
                  color: selected ? colors.text : colors.text2,
                ),
              ),
            ),
            Text(
              '$count',
              style: context.typo.label.copyWith(
                fontSize: 11,
                color: colors.text3,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TagChip extends StatelessWidget {
  const _TagChip(this.tag, {this.small = false});
  final String tag;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final c = _tagColor(tag, colors);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: small ? 5 : 8,
        vertical: small ? 1 : 2,
      ),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.withValues(alpha: 0.4)),
      ),
      child: Text(
        tag,
        style: context.typo.label.copyWith(
          fontSize: small ? 9.5 : 11,
          color: c,
        ),
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
