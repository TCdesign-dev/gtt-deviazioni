import 'package:flutter_test/flutter_test.dart';
import 'package:gtt_deviazioni/core/deviation_service.dart';
import 'package:gtt_deviazioni/core/geo/projection.dart';
import 'package:gtt_deviazioni/core/models/notice.dart';
import 'package:gtt_deviazioni/core/models/transit.dart';
import 'package:gtt_deviazioni/core/pipeline/stop_impact.dart';
import 'package:gtt_deviazioni/data/status_cache.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Una cache fa danni in due modi: restituendo qualcosa di sbagliato, o
/// impedendo all'app di partire quando e' corrotta. Questi test coprono
/// tutti e due.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final fermata = TransitStop(
    id: 'S1',
    code: '100',
    name: 'SABOTINO',
    position: const GeoPoint(45.070, 7.665),
  );
  final altra = TransitStop(
    id: 'S2',
    code: '200',
    name: 'SAN PAOLO',
    position: const GeoPoint(45.071, 7.666),
  );

  RouteShape shape(String id) => RouteShape(
        shapeId: id,
        routeId: '65U',
        directionId: 0,
        headsign: 'PORTA SUSA',
        points: const [GeoPoint(45.070, 7.660), GeoPoint(45.070, 7.690)],
        stops: [fermata, altra],
      );

  GtfsIndex indice({String feed = '20260801', String shapeId = '65:0'}) =>
      GtfsIndex(
        feedVersion: feed,
        builtAt: DateTime(2026, 8, 1),
        lines: {'65U': const TransitLine(routeId: '65U', shortName: '65')},
        shapes: {'65U': [shape(shapeId)]},
        stops: {fermata.id: fermata, altra.id: altra},
      );

  LineStatus stato(GtfsIndex index, {DateTime? quando}) {
    final s = index.shapes['65U']!.first;
    return LineStatus(
      line: index.lines['65U']!,
      shape: s,
      allShapes: [s],
      checkedAt: quando ?? DateTime.now(),
      reports: [
        DeviationReport(
          notice: RawNotice(
            id: 'a1',
            source: NoticeSource.gtfsRtAlert,
            text: 'Fermata 100 Sabotino sospesa.',
            routeIds: const ['65U'],
            validFrom: DateTime(2026, 8, 1),
            sourceUrl: 'x',
          ),
          shape: s,
          confidence: Confidence.confermata,
          deviatedGeometry: const [
            GeoPoint(45.069, 7.670),
            GeoPoint(45.069, 7.675),
          ],
          impact: StopImpactResult(
            impacts: [
              StopImpact(
                stop: fermata,
                status: StopStatus.declaredSuspended,
                alternatives: [
                  StopAlternative(
                      stop: altra, straightMeters: 140, sameLine: true),
                ],
              ),
            ],
            affectedFromMeters: 100,
            affectedToMeters: 900,
          ),
        ),
      ],
    );
  }

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('un esito salvato si rilegge intero', () async {
    final index = indice();
    await StatusCache.save([stato(index)], feedVersion: index.feedVersion);

    final letti = await StatusCache.load(index);
    expect(letti.keys, equals({'65U'}));

    final r = letti['65U']!.reports.single;
    expect(r.confidence, equals(Confidence.confermata));
    expect(r.notice.text, contains('Sabotino'));
    expect(r.deviatedGeometry, hasLength(2));
    // Le fermate si ripescano dall'indice: nella cache c'e' solo l'id.
    expect(r.skippedStops.single.stop.name, equals('SABOTINO'));
    expect(r.skippedStops.single.alternatives.single.stop.name,
        equals('SAN PAOLO'));
    expect(r.skippedStops.single.alternatives.single.sameLine, isTrue);
  });

  test('orari nuovi: la cache si butta invece di agganciarsi a percorsi '
      'che non esistono piu', () async {
    final vecchio = indice();
    await StatusCache.save([stato(vecchio)], feedVersion: '20260801');

    // Il giorno dopo GTT rigenera il GTFS.
    final nuovo = indice(feed: '20260802');
    expect(await StatusCache.load(nuovo), isEmpty);
  });

  test('un percorso sparito non produce un esito appeso al posto sbagliato',
      () async {
    await StatusCache.save([stato(indice())], feedVersion: '20260801');
    // Stesso feed, ma la shape ha cambiato identificatore.
    final index = indice(shapeId: '65:ALTRO');
    final letti = await StatusCache.load(index);
    // La linea c'e' ancora, il rapporto no: meglio niente che sbagliato.
    expect(letti['65U']?.reports, anyOf(isNull, isEmpty));
  });

  test('un esito piu vecchio di una settimana non si ripesca', () async {
    final index = indice();
    await StatusCache.save(
      [stato(index, quando: DateTime.now().subtract(const Duration(days: 8)))],
      feedVersion: index.feedVersion,
    );
    expect(await StatusCache.load(index), isEmpty);
  });

  test('di ieri invece si', () async {
    final index = indice();
    final ieri = DateTime.now().subtract(const Duration(days: 1));
    await StatusCache.save([stato(index, quando: ieri)],
        feedVersion: index.feedVersion);

    final letti = await StatusCache.load(index);
    expect(letti['65U'], isNotNull);
    expect(letti['65U']!.checkedAt.day, equals(ieri.day));
  });

  test('dati corrotti non impediscono all app di partire', () async {
    SharedPreferences.setMockInitialValues(
        {'esiti_controlli_v1': 'questo non e JSON'});
    expect(await StatusCache.load(indice()), isEmpty);
  });

  test('niente in cache, nessun problema', () async {
    expect(await StatusCache.load(indice()), isEmpty);
  });
}
