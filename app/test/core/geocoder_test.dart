import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gtt_deviazioni/core/geo/projection.dart';
import 'package:gtt_deviazioni/core/models/transit.dart';
import 'package:gtt_deviazioni/core/net/gtt_http.dart';
import 'package:gtt_deviazioni/core/pipeline/geocoder.dart';

/// Il vincolo geografico e' il cuore del passaggio testo -> geometria: e'
/// esattamente cio' che mancava al tentativo precedente del progetto.
/// Va verificato che scarti davvero, non solo che accetti.
///
/// Photon non viene interrogato: le risposte sono finte e costruite per
/// mettere alla prova la decisione. I test girano offline e in millisecondi.
void main() {
  // Un percorso dritto lungo corso Vittorio Emanuele II, ~1,6 km.
  final shape = RouteShape(
    shapeId: 'TEST:0:01',
    routeId: 'TESTU',
    directionId: 0,
    headsign: 'PROVA',
    points: const [
      GeoPoint(45.0623, 7.6786),
      GeoPoint(45.0640, 7.6700),
      GeoPoint(45.0655, 7.6600),
    ],
  );

  /// Costruisce una risposta Photon con i candidati dati, in ordine.
  String photonJson(List<({double lat, double lon, String name})> hits) =>
      jsonEncode({
        'type': 'FeatureCollection',
        'features': [
          for (final h in hits)
            {
              // GeoJSON e' [lon, lat]: se il codice li invertisse, il
              // risultato finirebbe in mezzo al mare e questi test lo
              // vedrebbero subito.
              'geometry': {
                'type': 'Point',
                'coordinates': [h.lon, h.lat]
              },
              'properties': {'name': h.name, 'city': 'Torino'},
            }
        ],
      });

  group('normalizeToponym — come GTT scrive davvero', () {
    test('abbreviazioni', () {
      expect(Geocoder.normalizeToponym('c.so Vittorio Emanuele II'),
          equals('corso Vittorio Emanuele II'));
      expect(Geocoder.normalizeToponym('p.zza Castello'),
          equals('piazza Castello'));
      expect(Geocoder.normalizeToponym('str. del Drosso'),
          equals('strada del Drosso'));
      expect(Geocoder.normalizeToponym('v.le Europa'), equals('viale Europa'));
      // Le abbreviazioni che finiscono col punto sono il caso fragile:
      // con \b in coda la sostituzione non avveniva mai, in silenzio.
      expect(Geocoder.normalizeToponym('sp. 180'),
          equals('strada provinciale 180'));
      expect(Geocoder.normalizeToponym('S.P. 180'),
          equals('strada provinciale 180'));
    });

    test('apostrofo tipografico: la trappola numero 12', () {
      // U+2019 contro U+0027. Compare davvero: "corso Massimo d'Azeglio",
      // "via dell'Arsenale".
      expect(Geocoder.normalizeToponym('corso Massimo d’Azeglio'),
          equals("corso Massimo d'Azeglio"));
      expect(Geocoder.normalizeToponym('via dell’Arsenale'),
          equals("via dell'Arsenale"));
    });

    test('spazi ridondanti e non separabili', () {
      expect(Geocoder.normalizeToponym('  via   Roma  '), equals('via Roma'));
      expect(Geocoder.normalizeToponym('via Roma'), equals('via Roma'));
    });

    test('un nome gia pulito resta identico', () {
      expect(Geocoder.normalizeToponym('via Asinari di Bernezzo'),
          equals('via Asinari di Bernezzo'));
    });
  });

  group('Il vincolo geografico', () {
    test('accetta un toponimo sul percorso', () async {
      final g = Geocoder(
        http: _FakeHttp(photonJson([
          (lat: 45.0640, lon: 7.6700, name: 'Corso Vittorio Emanuele II')
        ])),
      );
      final r = await g.locate('corso Vittorio', near: shape);
      expect(r.status, equals(GeocodeStatus.ok));
      expect(r.isUsable, isTrue);
      expect(r.metersFromRoute, lessThan(50));
    });

    test('SCARTA un omonimo lontano invece di usarlo', () async {
      // E' il caso che fa fallire tutto se gestito male: una via con lo
      // stesso nome in un altro quartiere. Misurato: le vie estranee alla
      // linea cadono a 1342 m o piu'.
      final g = Geocoder(
        http: _FakeHttp(photonJson([
          (lat: 45.1200, lon: 7.7400, name: 'Via Roma (Settimo)')
        ])),
      );
      final r = await g.locate('via Roma', near: shape);
      expect(r.status, equals(GeocodeStatus.outsideBuffer));
      expect(r.isUsable, isFalse,
          reason: 'un risultato fuori vincolo non deve mai essere usabile');
      // Il punto viene comunque riportato: serve a spiegare all\'utente
      // perche\' e\' stato scartato.
      expect(r.point, isNotNull);
      expect(r.metersFromRoute, greaterThan(1000));
    });

    test('fra piu candidati sceglie il piu vicino al percorso, non il primo',
        () async {
      // Photon ordina per rilevanza testuale, che non sa nulla di dove
      // passa l'autobus. Qui il primo candidato e' lontanissimo.
      final g = Geocoder(
        http: _FakeHttp(photonJson([
          (lat: 45.2000, lon: 7.9000, name: 'Via Garibaldi (Chivasso)'),
          (lat: 45.1500, lon: 7.8000, name: 'Via Garibaldi (Settimo)'),
          (lat: 45.0641, lon: 7.6702, name: 'Via Garibaldi (Torino)'),
        ])),
      );
      final r = await g.locate('via Garibaldi', near: shape);
      expect(r.status, equals(GeocodeStatus.ok));
      expect(r.osmName, equals('Via Garibaldi (Torino)'));
    });

    test('il buffer e configurabile e cambia davvero l esito', () async {
      final json = photonJson([
        (lat: 45.0700, lon: 7.6700, name: 'Via Media')
      ]);
      final stretto = Geocoder(http: _FakeHttp(json), bufferMeters: 100);
      final largo = Geocoder(http: _FakeHttp(json), bufferMeters: 5000);
      expect((await stretto.locate('x', near: shape)).status,
          equals(GeocodeStatus.outsideBuffer));
      expect((await largo.locate('x', near: shape)).status,
          equals(GeocodeStatus.ok));
    });

    test('nessun risultato non e un errore, ed e diverso da un errore',
        () async {
      final g = Geocoder(http: _FakeHttp(photonJson([])));
      final r = await g.locate('via inesistente', near: shape);
      expect(r.status, equals(GeocodeStatus.notFound));
      expect(r.point, isNull);
    });

    test('un errore di rete resta distinguibile: ritentare ha senso',
        () async {
      final g = Geocoder(http: _FailingHttp());
      final r = await g.locate('via Roma', near: shape);
      expect(r.status, equals(GeocodeStatus.error));
      expect(r.detail, isNotNull);
    });

    test('una risposta non JSON non fa cadere l app', () async {
      final g = Geocoder(http: _FakeHttp('<html>errore</html>'));
      final r = await g.locate('via Roma', near: shape);
      expect(r.status, equals(GeocodeStatus.error));
    });
  });

  group('Cache', () {
    test('non interroga due volte per lo stesso toponimo', () async {
      final http = _FakeHttp(photonJson([
        (lat: 45.0640, lon: 7.6700, name: 'Corso Vittorio Emanuele II')
      ]));
      final g = Geocoder(http: http);
      await g.locate('corso Vittorio', near: shape);
      await g.locate('corso Vittorio', near: shape);
      await g.locate('  c.so   Vittorio ', near: shape); // stessa cosa
      expect(http.calls, equals(1),
          reason: 'Photon e un servizio pubblico gratuito: '
              'non va interrogato due volte per la stessa via');
    });

    test('linee diverse non condividono il risultato', () async {
      // "via Roma" per la 55 e "via Roma" per la 30 sono due domande
      // diverse: il vincolo e' un altro percorso.
      final http = _FakeHttp(photonJson([
        (lat: 45.0640, lon: 7.6700, name: 'Via Roma')
      ]));
      final g = Geocoder(http: http);
      final other = RouteShape(
        shapeId: 'ALTRA:0:01',
        routeId: 'ALTRAU',
        directionId: 0,
        headsign: 'X',
        points: const [GeoPoint(45.10, 7.70), GeoPoint(45.11, 7.71)],
      );
      await g.locate('via Roma', near: shape);
      await g.locate('via Roma', near: other);
      expect(http.calls, equals(2));
    });
  });
}

/// GttHttp finto: restituisce sempre lo stesso corpo e conta le chiamate.
class _FakeHttp extends GttHttp {
  _FakeHttp(this.body);

  final String body;
  int calls = 0;

  @override
  Future<String> getTextPolite(String url) async {
    calls++;
    return body;
  }
}

class _FailingHttp extends GttHttp {
  @override
  Future<String> getTextPolite(String url) async =>
      throw GttHttpException(url, 503, 'servizio non disponibile');
}
