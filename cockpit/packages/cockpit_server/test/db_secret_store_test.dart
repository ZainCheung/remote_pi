import 'dart:io';

import 'package:cockpit_server/cockpit_server.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late String path;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('cockpit-secrets-test');
    path = '${dir.path}/db-secrets.json';
  });

  tearDown(() => dir.deleteSync(recursive: true));

  test('grava, lê e apaga', () {
    final store = DbSecretStore(path: path);
    expect(store.read('/srv/proj', 'dev'), isNull);

    store.write('/srv/proj', 'dev', 's3cr3t');
    expect(store.read('/srv/proj', 'dev'), 's3cr3t');

    store.delete('/srv/proj', 'dev');
    expect(store.read('/srv/proj', 'dev'), isNull);
  });

  test('outro processo lê o que este gravou', () {
    DbSecretStore(path: path).write('/srv/proj', 'dev', 's3cr3t');
    // Instância nova = cache vazio, ou seja: leu do disco de verdade.
    expect(DbSecretStore(path: path).read('/srv/proj', 'dev'), 's3cr3t');
  });

  test('a raiz do workspace faz parte da chave', () {
    final store = DbSecretStore(path: path);
    // `dev-local` é o nome de conexão mais provável do mundo; dois workspaces
    // do mesmo host não podem compartilhar o segredo por coincidência de nome.
    store.write('/srv/a', 'dev-local', 'senha-a');
    store.write('/srv/b', 'dev-local', 'senha-b');
    expect(store.read('/srv/a', 'dev-local'), 'senha-a');
    expect(store.read('/srv/b', 'dev-local'), 'senha-b');
  });

  test('apagar um não derruba os outros', () {
    final store = DbSecretStore(path: path);
    store.write('/srv/proj', 'a', '1');
    store.write('/srv/proj', 'b', '2');
    store.delete('/srv/proj', 'a');
    expect(store.read('/srv/proj', 'a'), isNull);
    expect(store.read('/srv/proj', 'b'), '2');
  });

  test('arquivo corrompido não derruba o servidor nem impede regravar', () {
    File(path)
      ..createSync(recursive: true)
      ..writeAsStringSync('{isto não é json');
    final store = DbSecretStore(path: path);
    expect(store.read('/srv/proj', 'dev'), isNull);
    store.write('/srv/proj', 'dev', 'nova');
    expect(DbSecretStore(path: path).read('/srv/proj', 'dev'), 'nova');
  });

  test('o arquivo nasce 0600', () {
    // Permissão POSIX; no Windows o equivalente é ACL e o teste não se aplica.
    if (Platform.isWindows) return;
    DbSecretStore(path: path).write('/srv/proj', 'dev', 's3cr3t');
    final mode = Process.runSync('stat', [
      '-c',
      '%a',
      path,
    ]).stdout.toString().trim();
    expect(mode, '600');
  });
}
