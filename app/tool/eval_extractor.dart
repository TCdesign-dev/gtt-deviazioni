// Banco di prova dell'estrattore, sui 34 avvisi annotati a mano.
//
// Serve a rispondere con una MISURA, non con un'opinione, alla domanda
// "quale modello conviene usare". Le fixture sono in
// ../tests/fixtures/annotations.json e sono state annotate leggendo il
// testo, non generandolo.
//
//   GEMINI_API_KEY=... dart run tool/eval_extractor.dart
//   OPENROUTER_API_KEY=... dart run tool/eval_extractor.dart --provider openrouter --model anthropic/claude-haiku-4.5
//
// Attenzione: le annotazioni di riferimento le ha prodotte un LLM e vanno
// riviste a mano. Finche' non lo sono, questo misura la COERENZA fra due
// modelli, non la verita'. Vale comunque per intercettare regressioni.

import 'dart:convert';
import 'dart:io';

import 'package:gtt_deviazioni/core/llm/gemini_client.dart';
import 'package:gtt_deviazioni/core/llm/llm_client.dart';
import 'package:gtt_deviazioni/core/llm/openrouter_client.dart';
import 'package:gtt_deviazioni/core/models/notice.dart';
import 'package:gtt_deviazioni/core/pipeline/extractor.dart';

Future<void> main(List<String> args) async {
  final provider = _arg(args, '--provider') ?? 'gemini';
  final model = _arg(args, '--model');
  final limit = int.tryParse(_arg(args, '--limit') ?? '') ?? 999;

  final LlmClient llm;
  if (provider == 'openrouter') {
    final key = Platform.environment['OPENROUTER_API_KEY'];
    if (key == null || key.isEmpty) {
      stderr.writeln('manca OPENROUTER_API_KEY');
      exit(1);
    }
    llm = OpenRouterClient(
        apiKey: key, model: model ?? 'google/gemini-flash-1.5');
  } else {
    final key = Platform.environment['GEMINI_API_KEY'];
    if (key == null || key.isEmpty) {
      stderr.writeln('manca GEMINI_API_KEY');
      exit(1);
    }
    llm = GeminiClient(apiKey: key, model: model ?? 'gemini-flash-latest');
  }

  final fixtures = File('../tests/fixtures/notices.json');
  final annotations = File('../tests/fixtures/annotations.json');
  if (!fixtures.existsSync() || !annotations.existsSync()) {
    stderr.writeln('fixture non trovate in ../tests/fixtures/');
    exit(1);
  }

  final notices = {
    for (final n in (jsonDecode(fixtures.readAsStringSync())
        as Map<String, dynamic>)['notices'] as List)
      (n as Map<String, dynamic>)['id'] as String: n
  };
  final truth = (jsonDecode(annotations.readAsStringSync())
      as Map<String, dynamic>)['annotations'] as Map<String, dynamic>;

  final extractor = NoticeExtractor(llm: llm);
  stdout.writeln('modello: ${llm.name}');
  stdout.writeln('avvisi annotati: ${truth.length}\n');

  var done = 0, failed = 0;
  var typeOk = 0, typeTot = 0;
  var detachOk = 0, detachTot = 0;
  var viasExact = 0, viaTot = 0, viaHit = 0;
  var municipalityOk = 0, municipalityTot = 0;
  var invented = 0;
  final problems = <String>[];

  for (final entry in truth.entries) {
    if (done >= limit) break;
    final id = entry.key;
    final raw = notices[id];
    if (raw == null) continue;
    done++;

    final notice = RawNotice(
      id: id,
      source: NoticeSource.webVariazioni,
      text: raw['raw_text'] as String? ?? '',
      headline: raw['header'] as String?,
      sourceUrl: '',
    );

    final result = await extractor.extract(notice);
    if (!result.isUsable) {
      failed++;
      problems.add('$id: $result');
      continue;
    }

    final expected =
        ((entry.value as Map<String, dynamic>)['deviations'] as List)
            .cast<Map<String, dynamic>>();
    final got = result.deviations;
    final lowerText = notice.fullText.toLowerCase();

    // Si confrontano in ordine, fino al minimo fra i due.
    final n = expected.length < got.length ? expected.length : got.length;
    for (var i = 0; i < n; i++) {
      final e = expected[i];
      final g = got[i];

      typeTot++;
      if (g.type.name == _norm(e['deviation_type'] as String?)) typeOk++;

      final eDetach =
          (e['detach_point'] as Map<String, dynamic>?)?['street'] as String?;
      if (eDetach != null) {
        detachTot++;
        if (_same(g.detachStreet, eDetach)) detachOk++;
      }

      final eVias = ((e['via_sequence'] as List?) ?? const [])
          .map((v) => (v as Map<String, dynamic>)['street'] as String)
          .toList();
      if (eVias.isNotEmpty) {
        viaTot += eVias.length;
        for (final v in eVias) {
          if (g.viaSequence.any((x) => _same(x, v))) viaHit++;
        }
        if (eVias.length == g.viaSequence.length &&
            List.generate(eVias.length,
                    (k) => _same(g.viaSequence[k], eVias[k]))
                .every((x) => x)) {
          viasExact++;
        }
      }

      final eMun = e['municipality'] as String?;
      if (eMun != null) {
        municipalityTot++;
        if (_same(g.municipality, eMun)) municipalityOk++;
      }

      // Il controllo che conta davvero: niente vie inventate. Il prompt lo
      // vieta esplicitamente ed e' il fallimento che porta a una mappa
      // sbagliata invece che a nessuna mappa.
      for (final t in g.allToponyms) {
        if (!lowerText.contains(t.toLowerCase())) {
          invented++;
          problems.add('$id: toponimo INVENTATO "$t"');
        }
      }
    }

    if (expected.length != got.length) {
      problems.add('$id: ${expected.length} deviazioni attese, '
          '${got.length} estratte');
    }
  }

  String pct(int a, int b) =>
      b == 0 ? 'n/d' : '${(100 * a / b).toStringAsFixed(1)}%';

  stdout.writeln('=' * 60);
  stdout.writeln('avvisi processati        : $done');
  stdout.writeln('estrazioni fallite       : $failed');
  stdout.writeln('tipo di variazione       : $typeOk/$typeTot  '
      '(${pct(typeOk, typeTot)})');
  stdout.writeln('punto di stacco          : $detachOk/$detachTot  '
      '(${pct(detachOk, detachTot)})');
  stdout.writeln('vie trovate              : $viaHit/$viaTot  '
      '(${pct(viaHit, viaTot)})');
  stdout.writeln('sequenze vie esatte      : $viasExact');
  stdout.writeln('comune                   : $municipalityOk/$municipalityTot  '
      '(${pct(municipalityOk, municipalityTot)})');
  stdout.writeln('>>> TOPONIMI INVENTATI   : $invented   '
      '${invented == 0 ? "(nessuno: e la cosa piu importante)" : "<<< DA GUARDARE"}');

  if (problems.isNotEmpty) {
    stdout.writeln('\nda guardare:');
    for (final p in problems.take(25)) {
      stdout.writeln('  $p');
    }
  }
}

String? _arg(List<String> args, String name) {
  final i = args.indexOf(name);
  return (i >= 0 && i + 1 < args.length) ? args[i + 1] : null;
}

String _norm(String? s) => (s ?? 'altro') == 'sostituzione_modale'
    ? 'sostituzioneModale'
    : (s ?? 'altro') == 'sospensione_fermate'
        ? 'sospensioneFermate'
        : (s ?? 'altro');

bool _same(String? a, String? b) {
  if (a == null || b == null) return a == b;
  String n(String s) => s
      .toLowerCase()
      .replaceAll('’', "'")
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return n(a) == n(b);
}
