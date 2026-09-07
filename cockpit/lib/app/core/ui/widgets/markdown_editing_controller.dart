import 'package:cockpit/app/core/ui/themes/themes.dart';
import 'package:flutter/widgets.dart';

/// `TextEditingController` que pinta markdown **ao vivo** enquanto se digita:
/// `**negrito**` sai em negrito, `# título` grande, `- [ ]` com marcador em
/// destaque, `` `código` `` mono com fundo. Os marcadores (`**`, `#`, `` ` ``…)
/// ficam **escondidos** (fonte ~0, transparentes) em todas as linhas menos na
/// linha do cursor, onde aparecem esmaecidos pra poder editar a sintaxe —
/// mesmo comportamento do live preview do Obsidian. O texto no disco é
/// markdown puro e o cursor anda caractere a caractere (os escondidos ainda
/// existem, só não ocupam espaço). É o "WYSIWYG possível" sobre um TextField:
/// um só modo, sem alternar fonte ↔ preview.
///
/// Mesma técnica do [CodeEditingController]: sobrescrever [buildTextSpan]. O
/// parser é por linha (blocos) + regex inline, tolerante — nunca lança e nunca
/// muda o texto.
class MarkdownEditingController extends TextEditingController {
  MarkdownEditingController({super.text}) {
    selection = const TextSelection.collapsed(offset: 0);
  }

  static final _heading = RegExp(r'^(#{1,6})( )(.*)$');
  static final _task = RegExp(r'^(\s*)([-*+] \[[ xX]\] )(.*)$');
  static final _bullet = RegExp(r'^(\s*)([-*+] )(.*)$');
  static final _numbered = RegExp(r'^(\s*)(\d+[.)] )(.*)$');
  static final _quote = RegExp(r'^(> ?)(.*)$');
  static final _fence = RegExp(r'^\s*(```|~~~)');
  static final _rule = RegExp(r'^\s*(-{3,}|\*{3,}|_{3,})\s*$');

  // Inline: código primeiro (dentro de `` ` `` nada mais vale), depois
  // negrito+itálico, negrito, itálico, riscado, imagem, link.
  static final _inline = RegExp(
    r'(`[^`\n]+`)'
    r'|(\*\*\*[^*\n]+?\*\*\*)'
    r'|(\*\*[^*\n]+?\*\*|__[^_\n]+?__)'
    r'|((?<![\w*])\*[^*\n]+?\*(?![\w*])|(?<![\w_])_[^_\n]+?_(?![\w_]))'
    r'|(~~[^~\n]+?~~)'
    r'|(!\[[^\]\n]*\]\([^)\n]*\))'
    r'|(\[[^\]\n]+\]\([^)\n]*\))',
  );

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final colors = context.colors;
    final typo = context.typo;
    final base = style ?? typo.body;
    final dim = base.copyWith(color: colors.text3);
    // Escondido: fonte quase zero e transparente — ocupa ~0px mas segue no
    // texto, então seleção/cursor continuam válidos.
    final hidden = base.copyWith(
      fontSize: 0.1,
      color: const Color(0x00000000),
      letterSpacing: 0,
    );
    final cursor = selection.isValid ? selection.extentOffset : -1;
    final mono = typo.mono.copyWith(
      fontSize: (base.fontSize ?? 14) - 1,
      color: colors.text,
      backgroundColor: colors.panel3,
    );

    final text = this.text;
    final spans = <InlineSpan>[];
    var inFence = false;
    var offset = 0;
    final lines = text.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final isLast = i == lines.length - 1;
      final nl = isLast ? '' : '\n';
      // Linha do cursor revela os marcadores; as outras escondem.
      final onCursor = cursor >= offset && cursor <= offset + line.length;
      final marker = onCursor ? dim : hidden;

      if (_fence.hasMatch(line)) {
        inFence = !inFence;
        spans.add(TextSpan(text: '$line$nl', style: marker));
      } else if (inFence) {
        spans.add(TextSpan(text: line, style: mono));
        if (nl.isNotEmpty) spans.add(TextSpan(text: nl, style: base));
      } else if (_rule.hasMatch(line)) {
        spans.add(TextSpan(text: '$line$nl', style: marker));
      } else if (_heading.firstMatch(line) case final m?) {
        final level = m.group(1)!.length;
        final size = switch (level) {
          1 => 1.6,
          2 => 1.35,
          3 => 1.18,
          _ => 1.05,
        };
        final hStyle = base.copyWith(
          fontSize: (base.fontSize ?? 14) * size,
          fontWeight: FontWeight.w700,
          color: colors.text,
          height: 1.4,
        );
        spans.add(
          TextSpan(
            text: '${m.group(1)}${m.group(2)}',
            style: onCursor ? hStyle.copyWith(color: colors.text3) : hidden,
          ),
        );
        spans.addAll(_inlineSpans(m.group(3)!, hStyle, colors, marker, mono));
        spans.add(TextSpan(text: nl, style: base));
      } else if (_task.firstMatch(line) case final m?) {
        final done = m.group(2)!.contains(RegExp(r'\[[xX]\]'));
        final mk = m.group(2)!; // "- [ ] "
        spans.add(TextSpan(text: m.group(1), style: base));
        // "- " some fora da linha do cursor; a caixa "[ ]"/"[x]" fica sempre.
        spans.add(TextSpan(text: mk.substring(0, 2), style: marker));
        spans.add(
          TextSpan(
            text: mk.substring(2),
            style: base.copyWith(
              color: done ? colors.online : colors.accent,
              fontWeight: FontWeight.w600,
            ),
          ),
        );
        final body = done
            ? base.copyWith(
                color: colors.text3,
                decoration: TextDecoration.lineThrough,
              )
            : base;
        spans.addAll(_inlineSpans(m.group(3)!, body, colors, marker, mono));
        spans.add(TextSpan(text: nl, style: base));
      } else if ((_bullet.firstMatch(line) ?? _numbered.firstMatch(line))
          case final m?) {
        spans.add(TextSpan(text: m.group(1), style: base));
        spans.add(
          TextSpan(
            text: m.group(2),
            style: base.copyWith(
              color: colors.accent,
              fontWeight: FontWeight.w600,
            ),
          ),
        );
        spans.addAll(_inlineSpans(m.group(3)!, base, colors, marker, mono));
        spans.add(TextSpan(text: nl, style: base));
      } else if (_quote.firstMatch(line) case final m?) {
        spans.add(
          TextSpan(
            text: m.group(1),
            style: onCursor ? base.copyWith(color: colors.accent) : hidden,
          ),
        );
        final q = base.copyWith(
          color: colors.text2,
          fontStyle: FontStyle.italic,
        );
        spans.addAll(_inlineSpans(m.group(2)!, q, colors, marker, mono));
        spans.add(TextSpan(text: nl, style: base));
      } else {
        spans.addAll(_inlineSpans(line, base, colors, marker, mono));
        spans.add(TextSpan(text: nl, style: base));
      }
      offset += line.length + nl.length;
    }
    assert(offset == text.length);
    return TextSpan(style: base, children: spans);
  }

  static List<InlineSpan> _inlineSpans(
    String s,
    TextStyle base,
    AppColors colors,
    TextStyle marker,
    TextStyle mono,
  ) {
    if (s.isEmpty) return const [];
    final out = <InlineSpan>[];
    var last = 0;
    for (final m in _inline.allMatches(s)) {
      if (m.start > last) {
        out.add(TextSpan(text: s.substring(last, m.start), style: base));
      }
      final tok = m.group(0)!;
      final mk = marker.fontSize == 0.1
          ? marker
          : marker.copyWith(fontSize: base.fontSize);
      if (m.group(1) != null) {
        // `código`
        out.add(TextSpan(text: '`', style: mk));
        out.add(
          TextSpan(
            text: tok.substring(1, tok.length - 1),
            style: mono.copyWith(fontSize: (base.fontSize ?? 14) - 1),
          ),
        );
        out.add(TextSpan(text: '`', style: mk));
      } else if (m.group(2) != null) {
        _wrapped(
          out,
          tok,
          3,
          mk,
          base.copyWith(
            fontWeight: FontWeight.w700,
            fontStyle: FontStyle.italic,
          ),
        );
      } else if (m.group(3) != null) {
        _wrapped(out, tok, 2, mk, base.copyWith(fontWeight: FontWeight.w700));
      } else if (m.group(4) != null) {
        _wrapped(out, tok, 1, mk, base.copyWith(fontStyle: FontStyle.italic));
      } else if (m.group(5) != null) {
        _wrapped(
          out,
          tok,
          2,
          mk,
          base.copyWith(
            color: colors.text3,
            decoration: TextDecoration.lineThrough,
          ),
        );
      } else if (m.group(6) != null) {
        // ![alt](src) — imagem: sempre esmaecida (nunca escondida, senão a
        // linha sumiria; a figura em si aparece na leitura).
        out.add(
          TextSpan(
            text: tok,
            style: base.copyWith(color: colors.text3),
          ),
        );
      } else {
        // [texto](url) — texto como link, url esmaecida.
        final close = tok.indexOf('](');
        out.add(TextSpan(text: '[', style: mk));
        out.add(
          TextSpan(
            text: tok.substring(1, close),
            style: base.copyWith(
              color: colors.gitUntracked,
              decoration: TextDecoration.underline,
            ),
          ),
        );
        out.add(TextSpan(text: tok.substring(close), style: mk));
      }
      last = m.end;
    }
    if (last < s.length) {
      out.add(TextSpan(text: s.substring(last), style: base));
    }
    return out;
  }

  static void _wrapped(
    List<InlineSpan> out,
    String tok,
    int n,
    TextStyle marker,
    TextStyle inner,
  ) {
    out.add(TextSpan(text: tok.substring(0, n), style: marker));
    out.add(TextSpan(text: tok.substring(n, tok.length - n), style: inner));
    out.add(TextSpan(text: tok.substring(tok.length - n), style: marker));
  }
}
