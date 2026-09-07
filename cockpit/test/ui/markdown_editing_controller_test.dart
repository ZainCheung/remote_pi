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
  });
}
