import 'package:cockpit/app/core/ui/themes/themes.dart';
import 'package:cockpit/app/core/ui/widgets/markdown_editing_controller.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' show ShadcnApp, Brightness;

void main() {
  testWidgets('span text round-trips the source exactly, bold gets w700', (
    tester,
  ) async {
    const src =
        '# Title\n\nSome **bold** and _it_ `code` ~~gone~~\n'
        '- [x] done\n- [ ] todo\n1. one\n> quote\n```\nx = 1\n```\n[a](http://b)';
    final c = MarkdownEditingController(text: src);
    late TextSpan span;
    await tester.pumpWidget(
      ShadcnApp(
        theme: buildTheme(brightness: Brightness.dark),
        home: Builder(
          builder: (context) {
            span = c.buildTextSpan(context: context, withComposing: false);
            return const SizedBox();
          },
        ),
      ),
    );
    expect(span.toPlainText(), src);
    var boldSeen = false;
    span.visitChildren((s) {
      if (s is TextSpan && s.text == 'bold') {
        boldSeen = s.style?.fontWeight == FontWeight.w700;
      }
      return true;
    });
    expect(boldSeen, isTrue);
    // Cursor no início (linha 1) → os `**` da linha 3 ficam escondidos.
    var hiddenStars = 0;
    span.visitChildren((s) {
      if (s is TextSpan && s.text == '**' && s.style?.fontSize == 0.1) {
        hiddenStars++;
      }
      return true;
    });
    expect(hiddenStars, 2);
  });

  test('Enter continues lists, numbering increments, empty item exits', () {
    final c = MarkdownEditingController(text: '- a');
    c.value = const TextEditingValue(
      text: '- a\n',
      selection: TextSelection.collapsed(offset: 4),
    );
    expect(c.text, '- a\n- ');
    expect(c.selection.baseOffset, 6);
    // item vazio + Enter → encerra
    c.value = const TextEditingValue(
      text: '- a\n- \n',
      selection: TextSelection.collapsed(offset: 7),
    );
    expect(c.text, '- a\n\n');
    final n = MarkdownEditingController(text: '1. x\n- [x] y');
    n.value = const TextEditingValue(
      text: '1. x\n\n- [x] y',
      selection: TextSelection.collapsed(offset: 5),
    );
    expect(n.text, '1. x\n2. \n- [x] y');
    final t = MarkdownEditingController(text: '- [x] y');
    t.value = const TextEditingValue(
      text: '- [x] y\n',
      selection: TextSelection.collapsed(offset: 8),
    );
    expect(t.text, '- [x] y\n- [ ] ');
  });
}
