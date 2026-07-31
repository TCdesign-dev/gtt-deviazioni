// Verifica dal vivo del geocoding vincolato, contro Photon vero.
//
// I test della suite usano risposte finte, perche' devono essere veloci e
// deterministici. Questo invece interroga il servizio reale e serve a due
// cose: confermare che il porting in Dart dia gli stessi risultati della
// versione Python (150/150 entro 2 km, 142/150 entro 500 m), e accorgersi
// se un giorno Photon cambia comportamento.
//
//   cd app && dart run tool/check_geocoding_live.dart
//
// Richiede il GTFS estratto in ../data/gtfs e la rete.

import 'dart:io';

import 'package:gtt_deviazioni/core/gtfs/gtfs_parser.dart';
import 'package:gtt_deviazioni/core/pipeline/geocoder.dart';

/// Toponimi presi dalle fixture annotate a mano, con la linea a cui
/// l'avviso si riferisce e il comune dichiarato da GTT.
const _cases = <({String line, String municipality, List<String> toponyms})>[
  (
    line: '55',
    municipality: 'Torino',
    toponyms: [
      'corso Racconigi',
      'piazza Sabotino',
      'via Di Nanni',
      'piazza Adriano',
      'corso Peschiera',
      'corso Vittorio Emanuele II',
    ]
  ),
  (
    line: '19',
    municipality: 'Torino',
    toponyms: [
      'via Cernaia',
      'corso Vinzaglio',
      'piazza XVIII Dicembre',
      'corso Bolzano',
      'corso Matteotti',
    ]
  ),
  (
    line: '65',
    municipality: 'Torino',
    toponyms: [
      'via Asinari di Bernezzo',
      'corso Monte Grappa',
      'piazza Chironi',
      'via Medici',
      'corso Lecce',
      'via Lessona',
    ]
  ),
  (
    line: '2C',
    municipality: 'Chieri',
    toponyms: [
      'corso Matteotti',
      'via Riva',
      'via Aldo Moro',
      'via Montù',
      'via Fani',
      'piazza Europa',
    ]
  ),
];

Future<void> main() async {
  final dir = Directory('../data/gtfs');
  if (!dir.existsSync()) {
    stderr.writeln('GTFS non estratto in ../data/gtfs');
    exit(1);
  }

  final lines = _cases.map((c) => c.line).toList();
  stdout.writeln('Carico il GTFS per ${lines.join(", ")}...');
  final index = await GtfsParser(directory: dir).build(lines, withStops: false);

  final geocoder = Geocoder();
  var total = 0, ok = 0, outside = 0, missing = 0, errors = 0;
  final distances = <double>[];

  for (final c in _cases) {
    final line = index.lineByShortName(c.line);
    if (line == null) {
      stdout.writeln('  linea ${c.line} non trovata, salto');
      continue;
    }
    final shape = index.mainShape(line.routeId, 0);
    if (shape == null) {
      stdout.writeln('  nessuna geometria per ${c.line}, salto');
      continue;
    }

    stdout.writeln('\nlinea ${c.line}  (${shape.shapeId}, '
        '${(shape.lengthMeters / 1000).toStringAsFixed(1)} km)');
    for (final t in c.toponyms) {
      total++;
      final r = await geocoder.locate(t,
          near: shape, municipality: c.municipality);
      switch (r.status) {
        case GeocodeStatus.ok:
          ok++;
          distances.add(r.metersFromRoute!);
        case GeocodeStatus.outsideBuffer:
          outside++;
          distances.add(r.metersFromRoute!);
        case GeocodeStatus.notFound:
          missing++;
        case GeocodeStatus.error:
          errors++;
      }
      stdout.writeln('  $r');
    }
  }

  distances.sort();
  stdout.writeln('\n${"=" * 62}');
  stdout.writeln('toponimi         : $total');
  stdout.writeln('entro il vincolo : $ok  '
      '(${(100 * ok / total).toStringAsFixed(1)}%)');
  stdout.writeln('fuori vincolo    : $outside');
  stdout.writeln('non trovati      : $missing');
  stdout.writeln('errori           : $errors');
  if (distances.isNotEmpty) {
    stdout.writeln('distanza dal percorso: mediana '
        '${distances[distances.length ~/ 2].round()} m, '
        'max ${distances.last.round()} m');
  }
}
