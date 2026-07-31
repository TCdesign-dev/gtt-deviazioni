import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gtt_deviazioni/core/deviation_service.dart';
import 'package:gtt_deviazioni/core/geo/projection.dart';
import 'package:gtt_deviazioni/core/models/notice.dart';
import 'package:gtt_deviazioni/core/models/transit.dart';
import 'package:gtt_deviazioni/core/pipeline/stop_impact.dart';
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

  LineStatus statusWith({
    List<GeoPoint>? deviated,
    List<StopImpact> skipped = const [],
  }) =>
      LineStatus(
        line: const TransitLine(routeId: 'TESTU', shortName: 'T'),
        shape: shape,
        checkedAt: DateTime(2026),
        reports: [
          DeviationReport(
            notice: notice,
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

  Future<void> pump(WidgetTester tester, LineStatus s) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: LineMap(status: s))));
    await tester.pump();
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

  testWidgets('le fermate non servite compaiono sulla mappa', (tester) async {
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
    // Due estremi della linea + una fermata saltata.
    final markers =
        tester.widget<MarkerLayer>(find.byType(MarkerLayer)).markers;
    expect(markers.length, equals(3));
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
}
