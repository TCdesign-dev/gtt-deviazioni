import 'dart:math' as math;

import 'projection.dart';

/// Geometria di base su polilinee. Tutto in metri, mai in gradi (§10.3).
///
/// E' il modulo con la maggior densita' di bug potenziali del progetto:
/// per questo non fa rete, non tocca il disco e si testa in millisecondi.
class Geometry {
  const Geometry._();

  /// Distanza da un punto al segmento AB.
  static double pointToSegment(Point p, Point a, Point b) {
    final dx = b.x - a.x;
    final dy = b.y - a.y;
    if (dx == 0 && dy == 0) return p.distanceTo(a);
    var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / (dx * dx + dy * dy);
    t = t.clamp(0.0, 1.0);
    return p.distanceTo(Point(a.x + t * dx, a.y + t * dy));
  }

  /// Distanza minima da un punto alla polilinea.
  /// Ritorna [double.infinity] se la polilinea e' vuota.
  static double pointToPolyline(Point p, List<Point> line) {
    if (line.isEmpty) return double.infinity;
    if (line.length == 1) return p.distanceTo(line.first);
    var best = double.infinity;
    for (var i = 0; i < line.length - 1; i++) {
      final d = pointToSegment(p, line[i], line[i + 1]);
      if (d < best) best = d;
    }
    return best;
  }

  /// Come [pointToPolyline], ma dice anche DOVE: utile per capire se due
  /// punti sono nello stesso tratto e in che ordine li incontra la linea.
  ///
  /// Con [fromAlong] si cerca solo **a valle** di quel punto del percorso.
  /// Serve quando una linea passa due volte vicino allo stesso posto: il
  /// rientro da una deviazione sta dopo il punto di stacco, non prima, e
  /// senza il vincolo si sceglierebbe il passaggio sbagliato.
  static Projected projectOnPolyline(
    Point p,
    List<Point> line, {
    double fromAlong = 0,
  }) {
    if (line.isEmpty) {
      return const Projected(double.infinity, -1, 0, 0);
    }
    var best = double.infinity;
    var bestIdx = 0;
    var bestT = 0.0;
    var bestAlong = 0.0;
    var along = 0.0;

    for (var i = 0; i < line.length - 1; i++) {
      final a = line[i];
      final b = line[i + 1];
      final segLen = a.distanceTo(b);
      final dx = b.x - a.x;
      final dy = b.y - a.y;
      var t = 0.0;
      if (dx != 0 || dy != 0) {
        t = (((p.x - a.x) * dx + (p.y - a.y) * dy) / (dx * dx + dy * dy))
            .clamp(0.0, 1.0);
      }
      final candidateAlong = along + segLen * t;
      final d = p.distanceTo(Point(a.x + t * dx, a.y + t * dy));
      if (d < best && candidateAlong >= fromAlong) {
        best = d;
        bestIdx = i;
        bestT = t;
        bestAlong = candidateAlong;
      }
      along += segLen;
    }
    return Projected(best, bestIdx, bestT, bestAlong);
  }

  /// Il punto sulla polilinea a [alongMeters] dall'inizio.
  /// Serve a materializzare un punto di rientro che sta ESATTAMENTE sul
  /// percorso ufficiale, non semplicemente vicino.
  static Point? pointAtAlong(List<Point> line, double alongMeters) {
    if (line.length < 2) return line.isEmpty ? null : line.first;
    if (alongMeters <= 0) return line.first;
    var along = 0.0;
    for (var i = 0; i < line.length - 1; i++) {
      final seg = line[i].distanceTo(line[i + 1]);
      if (along + seg >= alongMeters) {
        final t = seg == 0 ? 0.0 : (alongMeters - along) / seg;
        return Point(
          line[i].x + (line[i + 1].x - line[i].x) * t,
          line[i].y + (line[i + 1].y - line[i].y) * t,
        );
      }
      along += seg;
    }
    return line.last;
  }

  /// Lunghezza totale della polilinea in metri.
  static double length(List<Point> line) {
    var total = 0.0;
    for (var i = 0; i < line.length - 1; i++) {
      total += line[i].distanceTo(line[i + 1]);
    }
    return total;
  }

  /// Sotto-polilinea fra due indici (estremi inclusi).
  static List<Point> slice(List<Point> line, int from, int to) {
    if (line.isEmpty) return const [];
    final a = from.clamp(0, line.length - 1);
    final b = to.clamp(0, line.length - 1);
    return a <= b
        ? line.sublist(a, b + 1)
        : line.sublist(b, a + 1).reversed.toList();
  }

  /// Infittisce la polilinea in modo che nessun tratto superi [maxSpacing],
  /// **conservando tutti i vertici originali**.
  ///
  /// Serve PRIMA di [discreteFrechet]: la variante discreta accoppia solo
  /// vertici, quindi due campionamenti diversi dello stesso identico
  /// percorso danno una distanza pari al passo piu' rado. Con una shape
  /// GTFS (vertici ogni ~200 m) e una traccia GPS (un punto ogni 30 s) si
  /// otterrebbero centinaia di metri di differenza fantasma, e la soglia di
  /// 200 m della specifica scarterebbe accoppiamenti giusti.
  ///
  /// Si aggiungono punti senza toglierne: un ricampionamento a passo fisso
  /// che sostituisce i vertici **taglia gli angoli**, accorciando il
  /// percorso proprio nei punti di svolta, che sono quelli dove le
  /// deviazioni si distinguono.
  static List<Point> densify(List<Point> line, double maxSpacing) {
    if (line.length < 2 || maxSpacing <= 0) return List.of(line);
    final out = <Point>[];

    for (var i = 0; i < line.length - 1; i++) {
      final a = line[i];
      final b = line[i + 1];
      out.add(a);
      final segLen = a.distanceTo(b);
      if (segLen <= maxSpacing) continue;
      final n = (segLen / maxSpacing).ceil();
      for (var k = 1; k < n; k++) {
        final t = k / n;
        out.add(Point(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t));
      }
    }
    out.add(line.last);
    return out;
  }

  /// Distanza di Fréchet discreta fra due tracce.
  /// Serve a dire se due percorsi sono "lo stesso percorso" (§5.3.2):
  /// a differenza di una media di distanze, tiene conto dell'ordine.
  ///
  /// Se le due tracce hanno densita' di campionamento diverse, passale
  /// prima da [resample], altrimenti misuri il campionamento e non la forma.
  static double discreteFrechet(List<Point> p, List<Point> q) {
    if (p.isEmpty || q.isEmpty) return double.infinity;
    final ca = List.generate(p.length, (_) => List.filled(q.length, -1.0));

    double c(int i, int j) {
      if (ca[i][j] > -1) return ca[i][j];
      final d = p[i].distanceTo(q[j]);
      if (i == 0 && j == 0) {
        ca[i][j] = d;
      } else if (i == 0) {
        ca[i][j] = math.max(c(0, j - 1), d);
      } else if (j == 0) {
        ca[i][j] = math.max(c(i - 1, 0), d);
      } else {
        ca[i][j] = math.max(
          math.min(math.min(c(i - 1, j), c(i - 1, j - 1)), c(i, j - 1)),
          d,
        );
      }
      return ca[i][j];
    }

    return c(p.length - 1, q.length - 1);
  }

  /// Riquadro che contiene la polilinea, allargato di [paddingMeters].
  /// Serve al geocoding vincolato: si cerca solo qui dentro.
  static Bounds boundsOf(List<GeoPoint> pts, {double paddingMeters = 0}) {
    if (pts.isEmpty) {
      return const Bounds(0, 0, 0, 0);
    }
    var minLat = pts.first.lat, maxLat = pts.first.lat;
    var minLon = pts.first.lon, maxLon = pts.first.lon;
    for (final p in pts) {
      if (p.lat < minLat) minLat = p.lat;
      if (p.lat > maxLat) maxLat = p.lat;
      if (p.lon < minLon) minLon = p.lon;
      if (p.lon > maxLon) maxLon = p.lon;
    }
    final padLat = paddingMeters / Projection.metersPerDegreeLat;
    final padLon = paddingMeters / Projection.metersPerDegreeLon;
    return Bounds(
        minLat - padLat, minLon - padLon, maxLat + padLat, maxLon + padLon);
  }

  /// Baricentro, usato come bias per il geocoder.
  static GeoPoint centroid(List<GeoPoint> pts) {
    if (pts.isEmpty) return const GeoPoint(0, 0);
    var lat = 0.0, lon = 0.0;
    for (final p in pts) {
      lat += p.lat;
      lon += p.lon;
    }
    return GeoPoint(lat / pts.length, lon / pts.length);
  }
}

/// Esito della proiezione di un punto su una polilinea.
class Projected {
  const Projected(this.distance, this.segmentIndex, this.t, this.alongMeters);

  /// Distanza dal percorso, in metri.
  final double distance;

  /// Indice del segmento piu' vicino.
  final int segmentIndex;

  /// Posizione dentro il segmento, 0..1.
  final double t;

  /// Quanti metri di percorso sono stati fatti fino a qui.
  /// E' il valore che permette di ordinare le fermate lungo la linea.
  final double alongMeters;
}

class Bounds {
  const Bounds(this.minLat, this.minLon, this.maxLat, this.maxLon);

  final double minLat;
  final double minLon;
  final double maxLat;
  final double maxLon;

  bool contains(GeoPoint p) =>
      p.lat >= minLat && p.lat <= maxLat && p.lon >= minLon && p.lon <= maxLon;
}
