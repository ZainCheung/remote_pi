import 'package:cockpit/app/cockpit/domain/entities/gallery_template.dart';
import 'package:cockpit/app/cockpit/domain/entities/notebook_document.dart';
import 'package:cockpit/app/core/ui/file_icons/file_icon.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('.notebook folder is detected and gets the docs-folder icon', () {
    expect(isNotebookFolder('notes.notebook'), isTrue);
    expect(isNotebookFolder('Notes.NOTEBOOK'), isTrue);
    expect(isNotebookFolder('notebook'), isFalse);
    expect(fileIconName('notes.notebook'), 'folder-docs');
  });

  test('gallery notebook template creates the folder and opens it', () {
    final t = GalleryTemplate.notebook;
    expect(t.relativeDir, 'notes.notebook');
    expect(t.opensParent, isTrue);
    expect(t.fixedName, isTrue);
    expect(NotebookNote.parse('/x/welcome.md', t.content).tags, ['agent']);
  });
}
