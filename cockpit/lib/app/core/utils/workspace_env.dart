import 'dart:io';

/// Nome do arquivo de variáveis de ambiente por workspace.
///
/// Um `KEY=VALUE` por linha, injetado no ambiente de **todo terminal** que o
/// Cockpit abre naquele workspace (local). Mora na raiz do workspace de
/// propósito: o sufixo faz a maioria dos `.gitignore` (`.env*`) já ignorá-lo
/// e nenhuma lib de dotenv o lê por engano. Segredos de uso rápido (token,
/// e-mail/senha de uma API) entram aqui em vez de serem colados no prompt do
/// agente.
const kWorkspaceEnvFileName = '.env.cockpit';

/// Faz o parse de um `.env.cockpit`.
///
/// Gramática **deliberadamente burra**, pra não haver duas semânticas de
/// dotenv na mesma máquina:
/// - `KEY=VALUE`, uma por linha; espaços em volta da chave e do valor são
///   removidos;
/// - `#` no início da linha (após espaços) é comentário; linha vazia é ignorada;
/// - prefixo `export ` é aceito e descartado (cola de shell funciona);
/// - valor entre aspas simples ou duplas perde as aspas; **não** há escape,
///   interpolação (`$OUTRA`) nem multiline;
/// - chave inválida (vazia ou fora de `[A-Za-z_][A-Za-z0-9_]*`) é ignorada;
/// - chave repetida: a última vence.
Map<String, String> parseWorkspaceEnv(String source) {
  final out = <String, String>{};
  for (final raw in source.split(RegExp(r'\r?\n'))) {
    var line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    if (line.startsWith('export ')) line = line.substring(7).trimLeft();
    final eq = line.indexOf('=');
    if (eq <= 0) continue;
    final key = line.substring(0, eq).trim();
    if (!_kKeyPattern.hasMatch(key)) continue;
    var value = line.substring(eq + 1).trim();
    if (value.length >= 2) {
      final first = value[0];
      final last = value[value.length - 1];
      if ((first == '"' || first == "'") && first == last) {
        value = value.substring(1, value.length - 1);
      }
    }
    out[key] = value;
  }
  return out;
}

final _kKeyPattern = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

/// Lê e faz o parse do `.env.cockpit` de cada pasta em [roots], fundindo na
/// ordem dada (a última root vence em chave repetida). Pasta sem o arquivo,
/// ou arquivo ilegível, contribui com nada — o terminal abre igual.
///
/// Síncrono de propósito: o spawn do PTY é síncrono e acontece no construtor
/// da sessão; um arquivo de poucas linhas na raiz do workspace não justifica
/// tornar aquele caminho assíncrono.
Map<String, String> loadWorkspaceEnvSync(Iterable<String> roots) {
  final merged = <String, String>{};
  for (final root in roots) {
    if (root.isEmpty) continue;
    final file = File('$root${Platform.pathSeparator}$kWorkspaceEnvFileName');
    String source;
    try {
      if (!file.existsSync()) continue;
      source = file.readAsStringSync();
    } on FileSystemException {
      continue;
    }
    merged.addAll(parseWorkspaceEnv(source));
  }
  return merged;
}
