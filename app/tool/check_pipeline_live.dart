// Catena completa dal vivo, su deviazioni GTT vere.
//
// E' la prova che il progetto puo' funzionare: dal testo di un avviso alla
// geometria del percorso deviato, passando per geocoding vincolato e
// routing sulle strade reali. E' esattamente il passaggio che aveva fatto
// fallire il tentativo precedente.
//
//   cd app && dart run tool/check_pipeline_live.dart
//
// Richiede il GTFS estratto in ../data/gtfs e la rete.

import 'dart:io';

import 'package:gtt_deviazioni/core/geo/projection.dart';
import 'package:gtt_deviazioni/core/gtfs/gtfs_parser.dart';
import 'package:gtt_deviazioni/core/models/transit.dart';
import 'package:gtt_deviazioni/core/pipeline/geocoder.dart';
import 'package:gtt_deviazioni/core/pipeline/rejoin_inference.dart';
import 'package:gtt_deviazioni/core/pipeline/route_builder.dart';
import 'package:gtt_deviazioni/core/pipeline/stop_impact.dart';

/// Deviazioni prese dalla tabella GTT del 31/07/2026, con l'estrazione
/// gia' fatta a mano (il modulo LLM non c'e' ancora: qui si prova il
/// pezzo geometrico, non l'interpretazione del testo).
const _cases = <({
  String line,
  int direction,
  String municipality,
  String text,
  String detach,
  List<String> vias,
})>[
  (
    line: '65',
    // L'avviso dice "direzione corso Bolzano", che nel GTFS e' dir 1.
    // Con dir 0 la deduzione del rientro finisce a 2 km: la guardia lo
    // rifiuta, ed e' giusto cosi', ma il dato in ingresso era sbagliato.
    direction: 1,
    municipality: 'Torino',
    text: 'Da via Asinari di Bernezzo angolo corso Monte Grappa prosegue '
        'per via Asinari di Bernezzo, piazza Chironi, via Medici, '
        'corso Lecce, via Lessona, percorso normale.',
    detach: 'via Asinari di Bernezzo',
    vias: ['piazza Chironi', 'via Medici', 'corso Lecce', 'via Lessona'],
  ),
  (
    line: '94',
    direction: 0,
    municipality: 'Torino',
    text: 'Da via Monginevro deviata in corso Ferrucci, piazza Bernini, '
        'via Duchessa Jolanda, percorso normale.',
    detach: 'via Monginevro',
    vias: ['corso Ferrucci', 'piazza Bernini', 'via Duchessa Jolanda'],
  ),
  (
    line: '2C',
    direction: 0,
    municipality: 'Chieri',
    text: 'Nel Comune di Chieri. Da corso Matteotti angolo via Riva '
        'deviata in via Aldo Moro, via Montù, via Fani, via Conte Rossi '
        'di Montelera, piazza Europa, percorso normale.',
    detach: 'corso Matteotti',
    vias: [
      'via Aldo Moro',
      'via Montù',
      'via Fani',
      'via Conte Rossi di Montelera',
      'piazza Europa'
    ],
  ),
];

Future<void> main() async {
  final dir = Directory('../data/gtfs');
  if (!dir.existsSync()) {
    stderr.writeln('GTFS non estratto in ../data/gtfs');
    exit(1);
  }

  // Con le fermate: servono per l'impatto, ed e' la parte lenta (140 MB).
  final index = await GtfsParser(directory: dir)
      .build(_cases.map((c) => c.line).toList());
  final geocoder = Geocoder();
  final router = RouteBuilder();

  var built = 0, doubtful = 0, failed = 0;

  for (final c in _cases) {
    stdout.writeln('\n${'=' * 66}');
    stdout.writeln('LINEA ${c.line}');
    stdout.writeln(c.text);
    stdout.writeln('-' * 66);

    final line = index.lineByShortName(c.line);
    final shape =
        line == null ? null : index.mainShape(line.routeId, c.direction);
    if (shape == null) {
      stdout.writeln('  linea o geometria non trovata, salto');
      failed++;
      continue;
    }

    // 1. Geocoding vincolato al percorso di QUESTA linea.
    final toponyms = [c.detach, ...c.vias];
    final points = <GeoPoint>[];
    var geocodeOk = true;
    for (final t in toponyms) {
      final r =
          await geocoder.locate(t, near: shape, municipality: c.municipality);
      stdout.writeln('  $r');
      if (r.isUsable) {
        points.add(r.point!);
      } else {
        geocodeOk = false;
      }
    }
    if (!geocodeOk || points.length < 2) {
      stdout.writeln('  -> geometria non ricostruibile: '
          'si mostra il testo originale');
      failed++;
      continue;
    }

    // 1-bis. Dove rientra: l'avviso dice solo "percorso normale".
    final rejoin = RejoinInference.infer(
      officialRoute: shape,
      detachPoint: points.first,
      lastVia: points.last,
    );
    stdout.writeln('  $rejoin');

    // 2. Routing sulle strade reali, profilo bus.
    final route = await router.build(
      waypoints: [...points, if (rejoin.isUsable) rejoin.point!],
      officialRoute: shape,
      // Ogni via nominata deve essere attraversata: e' la prova che il
      // motore non ha preso un'altra strada.
      requiredVias: points.sublist(1),
    );

    stdout.writeln('  percorso: $route');
    switch (route.status) {
      case RouteBuildStatus.ok:
        built++;
        _reportStops(index, shape, route.geometry!);
      case RouteBuildStatus.validationFailed:
        doubtful++;
      case RouteBuildStatus.notRouted:
      case RouteBuildStatus.error:
        failed++;
    }
  }

  stdout.writeln('\n${'=' * 66}');
  stdout.writeln('ricostruiti e validati : $built/${_cases.length}');
  stdout.writeln('con riserva            : $doubtful');
  stdout.writeln('non ricostruiti        : $failed');
}

/// L'output che risponde alla domanda vera: la mia fermata e' servita?
void _reportStops(
    GtfsIndex index, RouteShape shape, List<GeoPoint> deviated) {
  final impact = StopImpactAnalyzer(index: index)
      .analyze(officialRoute: shape, deviatedRoute: deviated);

  stdout.writeln('  tratto interessato: '
      '${(impact.affectedFromMeters / 1000).toStringAsFixed(1)}-'
      '${(impact.affectedToMeters / 1000).toStringAsFixed(1)} km '
      'del percorso  (${impact.impacts.length} fermate)');

  if (!impact.hasImpact) {
    stdout.writeln('  nessuna fermata persa: il mezzo devia ma le serve tutte');
    return;
  }
  for (final i in impact.skipped) {
    stdout.writeln('  NON SERVITA: ${i.stop.name} [${i.stop.code}]');
    if (i.alternatives.isEmpty) {
      stdout.writeln('      nessuna alternativa entro 400 m');
    }
    for (final a in i.alternatives) {
      stdout.writeln('      -> $a');
    }
  }
  for (final i in impact.served) {
    stdout.writeln('  servita    : ${i.stop.name} [${i.stop.code}]');
  }
}
