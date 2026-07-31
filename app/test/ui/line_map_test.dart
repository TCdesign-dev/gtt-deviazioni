import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gtt_deviazioni/core/deviation_service.dart';
import 'package:gtt_deviazioni/core/geo/projection.dart';
import 'package:gtt_deviazioni/core/models/notice.dart';
import 'package:gtt_deviazioni/core/models/transit.dart';
import 'package:gtt_deviazioni/core/pipeline/stop_impact.dart';
import 'package:gtt_deviazioni/core/pipeline/vehicle_watch.dart';
import 'package:gtt_deviazioni/core/sources/vehicles_source.dart';
import 'package:gtt_deviazioni/ui/line_map.dart';

/// La mappa e' il pezzo che l'utente guarda per primo. Va verificata anche
/// quando i dati veri non sono disponibili: qui si costruisce uno stato
/// sintetico, cosi' il disegno del percorso deviato e' provato senza
/// dipendere dalla quota di un servizio esterno.
void main() {
  final shape = RouteShape(
    shapeId: 'T:0:01',
    routeId: 'TESTU',
    directionId: 0,
    headsign: 'PROVA',
    points: const [
      GeoPoint(45.0700, 7.6600),
      GeoPoint(45.0700, 7.6900),
    ],
    stops: const [
      TransitStop(
          id: 'S1',
          code: '100',
          name: 'Fermata 100',
          position: GeoPoint(45.0700, 7.6750)),
    ],
  );

  const notice = RawNotice(
    id: 'n1',
    source: NoticeSource.webVariazioni,
    text: 'Da via A deviata in via B, percorso normale.',
    sourceUrl: '',
  );

  /// Il ritorno: percorso diverso, come nella realta' (sensi unici).
  final ritorno = RouteShape(
    shapeId: 'T:1:01',
    routeId: 'TESTU',
    directionId: 1,
    headsign: 'RITORNO',
    points: const [
      GeoPoint(45.0710, 7.6900),
      GeoPoint(45.0710, 7.6600),
    ],
    stops: const [
      TransitStop(
          id: 'S2',
          code: '200',
          name: 'Fermata 200',
          position: GeoPoint(45.0710, 7.6750)),
    ],
  );

  LineStatus statusWith({
    List<GeoPoint>? deviated,
    List<StopImpact> skipped = const [],
    RouteShape? withReturn,
  }) =>
      LineStatus(
        line: const TransitLine(routeId: 'TESTU', shortName: 'T'),
        shape: shape,
        shapeReturn: withReturn,
        checkedAt: DateTime(2026),
        reports: [
          DeviationReport(
            notice: notice,
            shape: shape,
            confidence: deviated == null
                ? Confidence.soloTesto
                : Confidence.confermata,
            deviatedGeometry: deviated,
            impact: skipped.isEmpty
                ? null
                : StopImpactResult(
                    impacts: skipped,
                    affectedFromMeters: 0,
                    affectedToMeters: 500),
          ),
        ],
      );

  Future<void> pump(WidgetTester tester, LineStatus s,
      {List<VehicleTrack> vehicles = const []}) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: LineMap(status: s, vehicles: vehicles))));
    await tester.pump();
  }

  VehicleTrack track(String id, double lat, double lon, {int offPoints = 0}) {
    final t = VehicleTrack(id)
      ..points.add(VehicleObservation(
        vehicleId: id,
        routeId: 'TESTU',
        position: GeoPoint(lat, lon),
        seenAt: DateTime(2026, 8, 1, 10),
      ))
      ..offRoutePoints = offPoints;
    return t;
  }

  testWidgets('senza deviazione disegna comunque il percorso normale',
      (tester) async {
    await pump(tester, statusWith());

    final layer =
        tester.widget<PolylineLayer>(find.byType(PolylineLayer<Object>));
    expect(layer.polylines.length, equals(1),
        reason: 'una sola linea: il percorso normale');
    // E lo dichiara, invece di lasciare l'utente a indovinare.
    expect(find.text('deviazione non ricostruita'), findsOneWidget);
    expect(find.text('percorso normale'), findsOneWidget);
  });

  testWidgets('con la deviazione disegna DUE percorsi, distinguibili',
      (tester) async {
    await pump(
      tester,
      statusWith(deviated: const [
        GeoPoint(45.0700, 7.6700),
        GeoPoint(45.0680, 7.6750),
        GeoPoint(45.0700, 7.6800),
      ]),
    );

    final layer =
        tester.widget<PolylineLayer>(find.byType(PolylineLayer<Object>));
    expect(layer.polylines.length, equals(2));

    final normale = layer.polylines[0];
    final deviato = layer.polylines[1];

    // Il deviato deve essere sopra e piu' evidente: e' quello che conta.
    expect(deviato.strokeWidth, greaterThan(normale.strokeWidth));
    expect(deviato.color, isNot(equals(normale.color)));

    // Senza legenda due linee colorate non dicono nulla.
    expect(find.text('percorso deviato'), findsOneWidget);
    expect(find.text('percorso normale'), findsOneWidget);
  });

  testWidgets('disegna TUTTE le fermate, non solo quelle saltate',
      (tester) async {
    await pump(tester, statusWith());
    // Una fermata servita + due capolinea.
    final layers = tester
        .widgetList<MarkerLayer>(find.byType(MarkerLayer))
        .expand((l) => l.markers)
        .length;
    expect(layers, equals(3));
    expect(find.text('1 fermate'), findsOneWidget);
  });

  testWidgets('una fermata saltata non viene disegnata anche come servita',
      (tester) async {
    await pump(
      tester,
      statusWith(
        deviated: const [
          GeoPoint(45.0700, 7.6700),
          GeoPoint(45.0680, 7.6800),
        ],
        skipped: [
          StopImpact(stop: shape.stops.first, status: StopStatus.skipped),
        ],
      ),
    );
    expect(find.text('1 non servite'), findsOneWidget);
    // L'unica fermata e' saltata: niente pallino "servita" duplicato.
    expect(find.text('0 fermate'), findsOneWidget);
    final total = tester
        .widgetList<MarkerLayer>(find.byType(MarkerLayer))
        .expand((l) => l.markers)
        .length;
    expect(total, equals(3), reason: 'una saltata + due capolinea');
  });

  testWidgets('toccando una fermata compare il suo nome', (tester) async {
    // Dei pallini muti non servono: si tocca per sapere che fermata e'.
    await pump(tester, statusWith());
    expect(find.text('Fermata 100'), findsNothing);

    await tester.tap(find.byType(GestureDetector).first, warnIfMissed: false);
    await tester.pump();

    expect(find.text('Fermata 100'), findsOneWidget);
    expect(find.textContaining('servita'), findsOneWidget);
  });

  testWidgets('il bersaglio da toccare e piu grande del pallino visibile',
      (tester) async {
    // Verificato sul simulatore: con un marcatore di 11 px il tocco
    // mancava la fermata quasi sempre. Il pallino resta piccolo per non
    // coprire il percorso, l'area sensibile no.
    await pump(tester, statusWith());
    final marker = tester
        .widgetList<MarkerLayer>(find.byType(MarkerLayer))
        .expand((l) => l.markers)
        .first;
    expect(marker.width, greaterThanOrEqualTo(30),
        reason: 'un bersaglio da 11 px non si prende su un telefono');
    expect(marker.height, equals(marker.width));
  });

  testWidgets('una geometria degenere non fa cadere la schermata',
      (tester) async {
    final degenere = LineStatus(
      line: const TransitLine(routeId: 'X', shortName: 'X'),
      shape: RouteShape(
        shapeId: 'X:0:01',
        routeId: 'X',
        directionId: 0,
        headsign: '',
        points: const [GeoPoint(45.07, 7.68)],
      ),
      reports: const [],
      checkedAt: DateTime(2026),
    );
    await pump(tester, degenere);
    expect(find.byType(FlutterMap), findsNothing);
  });

  testWidgets('i mezzi osservati compaiono sulla mappa', (tester) async {
    await pump(tester, statusWith(), vehicles: [
      track('A', 45.0700, 7.6700),
      track('B', 45.0700, 7.6800),
    ]);

    expect(find.byIcon(Icons.directions_bus), findsNWidgets(2 + 1),
        reason: 'due mezzi sulla mappa piu quello della legenda');
    // L'ora dice quanto sono fresche: a osservazione finita i marcatori
    // restano sulla mappa e senza orario sembrerebbero attuali.
    expect(find.textContaining('2 in circolazione · 10:00'), findsOneWidget);
  });

  testWidgets('un mezzo fuori percorso si distingue da uno regolare',
      (tester) async {
    await pump(tester, statusWith(), vehicles: [
      track('A', 45.0700, 7.6700),
      track('B', 45.0670, 7.6800, offPoints: 3),
    ]);

    // Il colore e' l'informazione: rosso = sta deviando.
    final containers = tester
        .widgetList<Container>(find.ancestor(
            of: find.byIcon(Icons.directions_bus),
            matching: find.byType(Container)))
        .toList();
    final colours = containers
        .map((c) => (c.decoration as BoxDecoration?)?.color)
        .whereType<Color>()
        .toSet();
    expect(colours.length, greaterThanOrEqualTo(2),
        reason: 'i due mezzi non devono avere lo stesso colore');
  });

  testWidgets('senza osservazione in corso non si disegna nessun mezzo',
      (tester) async {
    await pump(tester, statusWith());
    expect(find.byIcon(Icons.directions_bus), findsNothing);
    expect(find.textContaining('in circolazione'), findsNothing);
  });

  testWidgets('disegna ENTRAMBE le direzioni, distinguibili', (tester) async {
    // Andata e ritorno sono percorsi diversi e una deviazione ne riguarda
    // spesso una sola: mostrarne una sola nasconde meta' della linea.
    await pump(tester, statusWith(withReturn: ritorno));

    final layer =
        tester.widget<PolylineLayer>(find.byType(PolylineLayer<Object>));
    expect(layer.polylines.length, equals(2));
    expect(layer.polylines[0].color, isNot(equals(layer.polylines[1].color)),
        reason: 'due direzioni dello stesso colore non si distinguono');

    // La legenda nomina i capolinea, non dice genericamente "percorso".
    expect(find.textContaining('PROVA'), findsOneWidget);
    expect(find.textContaining('RITORNO'), findsOneWidget);
  });

  testWidgets('con una direzione sola la legenda resta semplice',
      (tester) async {
    await pump(tester, statusWith());
    expect(find.text('percorso normale'), findsOneWidget);
  });

  testWidgets('mostra le fermate di entrambe le direzioni, senza doppioni',
      (tester) async {
    await pump(tester, statusWith(withReturn: ritorno));
    // Una fermata per direzione + due capolinea del solo percorso di
    // riferimento.
    expect(find.text('2 fermate'), findsOneWidget);
  });
}
