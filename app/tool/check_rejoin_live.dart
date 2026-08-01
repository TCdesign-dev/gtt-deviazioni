// Quanto regge l'IPOTESI su cui poggia la deduzione del rientro?
//
// L'ipotesi: l'ultima via nominata prima di "percorso normale" e' quella
// su cui il mezzo rientra, quindi giace sul percorso ufficiale.
//
// Questo strumento la misura SENZA passare dall'LLM e SENZA usare le
// annotazioni (che sono state scritte da un modello e non da una persona:
// valutarci sopra sarebbe circolare). Prende i testi veri, ne estrae le
// vie in ordine con una regex, geocodifica l'ultima con lo stesso
// geocoder vincolato dell'app, e misura quanto dista dal percorso.
//
//   cd app && dart run tool/check_rejoin_live.dart
import 'dart:io';

import 'package:gtt_deviazioni/core/config.dart';
import 'package:gtt_deviazioni/core/geo/geometry.dart';
import 'package:gtt_deviazioni/core/gtfs/csv.dart';
import 'package:gtt_deviazioni/core/gtfs/gtfs_parser.dart';
import 'package:gtt_deviazioni/core/models/notice.dart';
import 'package:gtt_deviazioni/core/models/transit.dart';
import 'package:gtt_deviazioni/core/pipeline/geocoder.dart';
import 'package:gtt_deviazioni/core/pipeline/line_resolver.dart';
import 'package:gtt_deviazioni/core/sources/alerts_source.dart';
import 'package:gtt_deviazioni/core/sources/variazioni_source.dart';

/// Le vie nominate, IN ORDINE, fino alla frase di rientro.
List<String> viePrimaDelRientro(String testo) {
  final t = testo.toLowerCase().replaceAll('’', "'");
  final fine = RegExp(r'(segue|riprende|prosegue con)?\s*(il\s+)?percorso\s+normale')
      .firstMatch(t);
  final parte = fine == null ? t : t.substring(0, fine.start);

  const qualificatori = {
    'via', 'viale', 'corso', 'piazza', 'piazzale', 'largo', 'strada',
    'ponte', 'rotatoria', 'vicolo',
  };
  // Le stesse parole-non-nome curate in NoticeMerge, sui dati veri.
  const nonNome = {
    'angolo', 'presso', 'seguono', 'segue', 'prosegue', 'proseguono',
    'riprende', 'deviata', 'deviate', 'deviato', 'percorso', 'normale',
    'causa', 'lavori', 'fermata', 'fermate', 'sospesa', 'direzione',
    'capolinea', 'linea', 'linee', 'dalle', 'dalla', 'dopo', 'prima',
    'sino', 'fino', 'quindi', 'nella', 'sulla', 'verso', 'effettua',
    'istituita', 'gestita', 'comune', 'temporaneamente', 'servizio',
    'carreggiata', 'laterale', 'partire', 'tutte', 'circa', 'dove',
    'alla', 'alle', 'sono', 'saranno', 'anche', 'oltre', 'della',
    'delle', 'dello', 'degli', 'lato', 'compresa', 'appositamente',
    'lunedi', 'martedi', 'mercoledi', 'giovedi', 'venerdi', 'sabato',
    'domenica', 'ore', 'via', 'attuale', 'regolare',
  };
  final parole = parte.split(RegExp(r"[^a-zà-ù0-9']+"))
      .where((w) => w.isNotEmpty).toList();
  final out = <String>[];
  for (var i = 0; i < parole.length; i++) {
    if (!qualificatori.contains(parole[i])) continue;
    // "direzione corso X" e' un capolinea, non una via percorsa.
    if (i > 0 && parole[i - 1].startsWith('direzion')) continue;
    final nome = <String>[];
    for (var j = i + 1; j < parole.length && j <= i + 3; j++) {
      if (qualificatori.contains(parole[j]) || nonNome.contains(parole[j])) {
        break;
      }
      if (parole[j].length < 4) break;
      nome.add(parole[j]);
    }
    if (nome.isNotEmpty) out.add('${parole[i]} ${nome.join(' ')}');
  }
  return out;
}

Future<void> main() async {
  final dir = Directory('../data/gtfs');
  if (!File('${dir.path}/routes.txt').existsSync()) {
    stdout.writeln('manca il GTFS in ../data/gtfs');
    exit(1);
  }

  final nomi = <String>[];
  var cols = <String, int>{};
  final righe = await File('${dir.path}/routes.txt').readAsLines();
  for (var i = 0; i < righe.length; i++) {
    final r = Csv.split(righe[i]);
    if (i == 0) { cols = Csv.header(righe[i]); continue; }
    final s = Csv.field(r, cols, 'route_short_name');
    if (s != null && s.isNotEmpty) nomi.add(s);
  }
  final index = await GtfsParser(directory: dir).build(nomi, withStops: false);
  final resolver = LineResolver(index);

  final avvisi = <RawNotice>[
    ...AlertsSource().parse(File('test/fixtures/alerts.pb').readAsBytesSync()),
    ...VariazioniSource()
        .parse(File('test/fixtures/variazioni.html').readAsStringSync()),
  ].where((n) => n.mentionsRouteChange).toList();

  final geocoder = Geocoder();
  final distanze = <double>[];
  var senzaVie = 0, senzaLinea = 0, nonRisolta = 0;
  final fuori = <String>[];

  stdout.writeln('avvisi di variazione: ${avvisi.length}\n');
  stdout.writeln('linea\tdist\tultima via nominata');

  for (final n in avvisi) {
    if (!RegExp(r'percorso\s+normale', caseSensitive: false)
        .hasMatch(n.fullText)) {
      continue;
    }

    final vie = viePrimaDelRientro(n.fullText);
    if (vie.isEmpty) {
      senzaVie++;
      continue;
    }

    TransitLine? linea;
    for (final id in n.routeIds) {
      linea = index.lines[id];
      if (linea != null) break;
    }
    linea ??= n.lineHints
        .map(resolver.resolveOne)
        .firstWhere((l) => l != null, orElse: () => null);
    if (linea == null) {
      senzaLinea++;
      continue;
    }

    final shape = index.mainShape(linea.routeId, 0);
    if (shape == null) {
      senzaLinea++;
      continue;
    }

    final ultima = vie.last;
    final r = await geocoder.locate(ultima, near: shape);
    if (!r.isUsable) {
      nonRisolta++;
      continue;
    }

    final d = Geometry.pointToPolyline(r.point!.meters, shape.meters);
    distanze.add(d);
    stdout.writeln('${linea.shortName}\t${d.round()} m\t$ultima');
    if (d > GttConfig.rejoinMaxViaDistanceMeters) {
      fuori.add('${linea.shortName}: $ultima a ${d.round()} m');
    }
    await Future<void>.delayed(const Duration(milliseconds: 700));
  }

  distanze.sort();
  double pct(int p) => distanze.isEmpty
      ? 0
      : distanze[((distanze.length - 1) * p / 100).round()];

  stdout.writeln('\n--- ${distanze.length} casi misurati ---');
  stdout.writeln('mediana        ${pct(50).round()} m');
  stdout.writeln('75 pct         ${pct(75).round()} m');
  stdout.writeln('90 pct         ${pct(90).round()} m');
  stdout.writeln('massimo        ${pct(100).round()} m');
  final entro = distanze.where((d) => d <= 100).length;
  stdout.writeln('entro 100 m    $entro/${distanze.length}');
  final accettati = distanze
      .where((d) => d <= GttConfig.rejoinMaxViaDistanceMeters).length;
  stdout.writeln('sotto la soglia dei ${GttConfig.rejoinMaxViaDistanceMeters.round()} m  '
      '$accettati/${distanze.length}');
  stdout.writeln('\nscartati: $senzaVie senza vie, $senzaLinea senza linea, '
      '$nonRisolta non geocodificate');
  if (fuori.isNotEmpty) {
    stdout.writeln('\noltre soglia (il sistema dichiara di non sapere):');
    for (final f in fuori) {
      stdout.writeln('  $f');
    }
  }
}
