import 'package:flutter_test/flutter_test.dart';
import 'package:gtt_deviazioni/core/geo/geometry.dart';
import 'package:gtt_deviazioni/core/geo/polyline.dart';
import 'package:gtt_deviazioni/core/geo/projection.dart';

/// I valori attesi non sono presi dall'output di questo codice: sono
/// calcolati a parte (Python, haversine e libreria polyline di riferimento)
/// e incollati qui. Un test che si limita a ricopiare cio' che il codice
/// gia' produce non verifica nulla.
void main() {
  group('Projection', () {
    test('metri per grado di longitudine alla latitudine di Torino', () {
      expect(Projection.metersPerDegreeLon, closeTo(78618.8995, 0.001));
    });

    test('distanza Porta Nuova - Porta Susa', () {
      // Riferimento haversine: 1509.56 m. La proiezione locale da' 1509.84,
      // cioe' uno scarto dello 0,019%: irrilevante per soglie da 40-1000 m.
      final a = const GeoPoint(45.0623, 7.6786).meters;
      final b = const GeoPoint(45.0723, 7.6656).meters;
      expect(a.distanceTo(b), closeTo(1509.84, 0.5));
    });

    test('scarta le posizioni spazzatura del feed realtime', () {
      // MISURATO: ~3% dei mezzi GTT pubblica esattamente questo.
      expect(const GeoPoint(0, 0).isPlausible, isFalse);
      expect(const GeoPoint(45.07, 7.68).isPlausible, isTrue);
      // Milano: fuori dal bacino GTT, va scartata.
      expect(const GeoPoint(45.4642, 9.1900).isPlausible, isFalse);
    });

    test('andata e ritorno gradi -> metri -> gradi', () {
      const p = GeoPoint(45.0678, 7.6482);
      final (lat, lon) = Projection.toDegrees(p.meters);
      expect(lat, closeTo(p.lat, 1e-9));
      expect(lon, closeTo(p.lon, 1e-9));
    });
  });

  group('Geometry.pointToSegment', () {
    test('proiezione perpendicolare dentro il segmento', () {
      expect(
        Geometry.pointToSegment(
            const Point(0, 5), const Point(0, 0), const Point(10, 0)),
        closeTo(5, 1e-9),
      );
    });

    test('oltre gli estremi misura dal vertice, non dalla retta', () {
      // Se si usasse la distanza dalla RETTA verrebbe 0: errore classico.
      expect(
        Geometry.pointToSegment(
            const Point(20, 0), const Point(0, 0), const Point(10, 0)),
        closeTo(10, 1e-9),
      );
    });

    test('segmento degenere', () {
      expect(
        Geometry.pointToSegment(
            const Point(3, 4), const Point(0, 0), const Point(0, 0)),
        closeTo(5, 1e-9),
      );
    });
  });

  group('Geometry.pointToPolyline', () {
    final line = [
      const Point(0, 0),
      const Point(100, 0),
      const Point(100, 100),
    ];

    test('trova il segmento piu vicino, non il primo', () {
      expect(Geometry.pointToPolyline(const Point(110, 50), line),
          closeTo(10, 1e-9));
    });

    test('polilinea vuota non esplode', () {
      expect(Geometry.pointToPolyline(const Point(0, 0), const []),
          equals(double.infinity));
    });

    test('polilinea con un punto solo', () {
      expect(
        Geometry.pointToPolyline(const Point(3, 4), const [Point(0, 0)]),
        closeTo(5, 1e-9),
      );
    });
  });

  group('Geometry.projectOnPolyline', () {
    test('riporta quanti metri di percorso sono stati fatti', () {
      final line = [
        const Point(0, 0),
        const Point(100, 0),
        const Point(100, 100),
      ];
      final r = Geometry.projectOnPolyline(const Point(100, 40), line);
      expect(r.distance, closeTo(0, 1e-9));
      expect(r.segmentIndex, equals(1));
      // 100 m del primo segmento + 40 m dentro il secondo.
      expect(r.alongMeters, closeTo(140, 1e-6));
    });

    test('alongMeters ordina le fermate lungo la linea', () {
      final line = [const Point(0, 0), const Point(1000, 0)];
      final a = Geometry.projectOnPolyline(const Point(200, 5), line);
      final b = Geometry.projectOnPolyline(const Point(700, 5), line);
      expect(a.alongMeters, lessThan(b.alongMeters));
    });
  });

  group('Geometry.projectOnPolyline con vincolo a valle', () {
    // Un percorso che torna vicino a se stesso: senza vincolo si
    // sceglierebbe il passaggio sbagliato.
    final andataERitorno = [
      const Point(0, 0),
      const Point(1000, 0),
      const Point(1000, 100),
      const Point(0, 100),
    ];

    test('senza vincolo prende il passaggio piu vicino, che puo essere '
        'quello di andata', () {
      final r = Geometry.projectOnPolyline(const Point(200, 10),
          andataERitorno);
      expect(r.alongMeters, closeTo(200, 1));
    });

    test('col vincolo prende il passaggio a valle', () {
      // Il punto di stacco e' a 1500 m: il rientro deve stare dopo.
      final r = Geometry.projectOnPolyline(const Point(200, 10),
          andataERitorno, fromAlong: 1500);
      expect(r.alongMeters, greaterThan(1500));
      // Sul ritorno, alla stessa ascissa: 1000 + 100 + (1000-200) = 1900.
      expect(r.alongMeters, closeTo(1900, 5));
    });

    test('se a valle non c e piu percorso, non inventa', () {
      final r = Geometry.projectOnPolyline(const Point(200, 10),
          andataERitorno, fromAlong: 99999);
      expect(r.distance, equals(double.infinity));
    });
  });

  group('Geometry.pointAtAlong', () {
    final line = [const Point(0, 0), const Point(100, 0), const Point(100, 50)];

    test('materializza un punto sul percorso', () {
      expect(Geometry.pointAtAlong(line, 0), equals(const Point(0, 0)));
      expect(Geometry.pointAtAlong(line, 50), equals(const Point(50, 0)));
      expect(Geometry.pointAtAlong(line, 120)!.y, closeTo(20, 1e-9));
    });

    test('oltre la fine restituisce la fine, non null', () {
      expect(Geometry.pointAtAlong(line, 99999), equals(const Point(100, 50)));
    });

    test('casi degeneri', () {
      expect(Geometry.pointAtAlong(const [], 10), isNull);
      expect(Geometry.pointAtAlong(const [Point(3, 4)], 10),
          equals(const Point(3, 4)));
    });
  });

  group('Geometry.length e slice', () {
    final line = [
      const Point(0, 0),
      const Point(30, 40), // 50 m
      const Point(30, 140), // 100 m
    ];

    test('lunghezza', () {
      expect(Geometry.length(line), closeTo(150, 1e-9));
    });

    test('slice inclusivo agli estremi', () {
      expect(Geometry.slice(line, 0, 1).length, equals(2));
      expect(Geometry.slice(line, 1, 2).first, equals(const Point(30, 40)));
    });

    test('slice con indici invertiti torna il tratto al contrario', () {
      final s = Geometry.slice(line, 2, 0);
      expect(s.first, equals(const Point(30, 140)));
      expect(s.last, equals(const Point(0, 0)));
    });

    test('slice fuori intervallo non esplode', () {
      expect(Geometry.slice(line, -5, 99).length, equals(3));
      expect(Geometry.slice(const [], 0, 3), isEmpty);
    });
  });

  group('Geometry.discreteFrechet', () {
    test('tracce identiche', () {
      final a = [const Point(0, 0), const Point(10, 0)];
      expect(Geometry.discreteFrechet(a, a), closeTo(0, 1e-9));
    });

    test('traccia traslata: la distanza e la traslazione', () {
      final a = [const Point(0, 0), const Point(10, 0), const Point(20, 0)];
      final b = [const Point(0, 7), const Point(10, 7), const Point(20, 7)];
      expect(Geometry.discreteFrechet(a, b), closeTo(7, 1e-9));
    });

    test('la variante discreta e sensibile al campionamento: e un fatto, '
        'non un bug', () {
      // Stesso identico percorso, campionato diversamente. La Frechet
      // discreta accoppia solo vertici, quindi il punto (50,0) di b non
      // ha un vertice vicino in a: la distanza vale 50 m di puro
      // campionamento. E' il motivo per cui esiste densify().
      final a = [const Point(0, 0), const Point(100, 0)];
      final b = [
        const Point(0, 0),
        const Point(25, 0),
        const Point(50, 0),
        const Point(100, 0),
      ];
      expect(Geometry.discreteFrechet(a, b), closeTo(50, 1e-9));
    });

    test('dopo il ricampionamento lo stesso percorso torna vicino a zero', () {
      final a = [const Point(0, 0), const Point(100, 0)];
      final b = [
        const Point(0, 0),
        const Point(25, 0),
        const Point(50, 0),
        const Point(100, 0),
      ];
      final ra = Geometry.densify(a, 10);
      final rb = Geometry.densify(b, 10);
      expect(Geometry.discreteFrechet(ra, rb), lessThan(11));
    });

    test('un percorso davvero diverso resta lontano anche ricampionato', () {
      final a = Geometry.densify(
          [const Point(0, 0), const Point(100, 0)], 10);
      final c = Geometry.densify(
          [const Point(0, 0), const Point(0, 500)], 10);
      expect(Geometry.discreteFrechet(a, c), greaterThan(400));
    });
  });

  group('Geometry.densify', () {
    test('nessun tratto oltre il passo, estremi conservati', () {
      final line = [const Point(0, 0), const Point(100, 0)];
      final r = Geometry.densify(line, 25);
      expect(r.first, equals(const Point(0, 0)));
      expect(r.last, equals(const Point(100, 0)));
      for (var i = 0; i < r.length - 1; i++) {
        expect(r[i].distanceTo(r[i + 1]), lessThanOrEqualTo(25.001));
      }
    });

    test('conserva ESATTAMENTE la lunghezza, angoli compresi', () {
      final line = [
        const Point(0, 0),
        const Point(300, 0),
        const Point(300, 400),
      ];
      expect(Geometry.length(Geometry.densify(line, 17)),
          closeTo(Geometry.length(line), 1e-6));
    });

    test('casi degeneri', () {
      expect(Geometry.densify(const [], 10), isEmpty);
      expect(Geometry.densify(const [Point(1, 1)], 10).length, equals(1));
      // Passo non valido: ritorna la linea invariata invece di ciclare.
      expect(Geometry.densify(
          [const Point(0, 0), const Point(10, 0)], 0).length, equals(2));
    });
  });

  group('Geometry.boundsOf', () {
    test('il padding e in metri, non in gradi', () {
      const pts = [GeoPoint(45.07, 7.68)];
      final b = Geometry.boundsOf(pts, paddingMeters: 1000);
      // 1000 m di latitudine ~ 0.009 gradi; di longitudine ~ 0.0127.
      expect(b.maxLat - 45.07, closeTo(1000 / 111132.0, 1e-9));
      expect(b.maxLon - 7.68, closeTo(1000 / 78618.8995, 1e-9));
      // Il riquadro e' piu' largo in longitudine: e' corretto a 45 gradi.
      expect(b.maxLon - b.minLon, greaterThan(b.maxLat - b.minLat));
    });

    test('lista vuota non esplode', () {
      expect(Geometry.boundsOf(const []).minLat, equals(0));
    });
  });

  group('PolylineCodec', () {
    // Stringa prodotta dalla libreria polyline di riferimento (Python).
    const encoded = 'kf`rGgvzm@o}@fpA';

    test('decodifica un campione noto', () {
      final pts = PolylineCodec.decode(encoded);
      expect(pts.length, equals(2));
      expect(pts[0].lat, closeTo(45.0623, 1e-5));
      expect(pts[0].lon, closeTo(7.6786, 1e-5));
      expect(pts[1].lat, closeTo(45.0723, 1e-5));
      expect(pts[1].lon, closeTo(7.6656, 1e-5));
    });

    test('codifica: andata e ritorno', () {
      const original = [
        GeoPoint(45.0623, 7.6786),
        GeoPoint(45.0723, 7.6656),
        GeoPoint(45.0801, 7.6601),
      ];
      final round = PolylineCodec.decode(PolylineCodec.encode(original));
      expect(round.length, equals(original.length));
      for (var i = 0; i < original.length; i++) {
        expect(round[i].lat, closeTo(original[i].lat, 1e-5));
        expect(round[i].lon, closeTo(original[i].lon, 1e-5));
      }
    });

    test('stringa vuota', () {
      expect(PolylineCodec.decode(''), isEmpty);
    });
  });
}
