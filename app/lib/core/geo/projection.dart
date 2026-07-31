import 'dart:math' as math;

import '../config.dart';

/// Conversione gradi -> metri per i calcoli geometrici.
///
/// La specifica (§10.3) insiste su EPSG:32632 e mette "lavorare in gradi
/// invece che in metri" al terzo posto fra le trappole che fanno perdere
/// piu' tempo. Il punto vero e' quello: **non calcolare mai distanze in
/// gradi**. Qui si usa una proiezione equirettangolare locale ancorata a
/// Torino invece della UTM piena: su un'area di ~30 km l'errore e' sotto
/// lo 0,1%, cioe' meno di 1 m su 1 km, del tutto trascurabile rispetto
/// alle soglie in gioco (40-1000 m). In cambio si evita una dipendenza
/// da proj4 sul telefono.
///
/// Se un giorno servisse precisione cartografica vera, questa e' l'unica
/// classe da sostituire: tutto il resto lavora gia' su metri.
class Projection {
  /// Metri per grado di latitudine (praticamente costante).
  static const metersPerDegreeLat = 111132.0;

  /// Metri per grado di longitudine alla latitudine di riferimento.
  static final metersPerDegreeLon =
      111320.0 * math.cos(GttConfig.refLatitude * math.pi / 180.0);

  /// Da (lat, lon) a coordinate piane in metri.
  static Point toMeters(double lat, double lon) =>
      Point(lat * metersPerDegreeLat, lon * metersPerDegreeLon);

  /// Inversa, per riportare un risultato sulla mappa.
  static (double lat, double lon) toDegrees(Point p) =>
      (p.x / metersPerDegreeLat, p.y / metersPerDegreeLon);

  /// Una posizione e' plausibile se cade nel bacino GTT.
  /// Scarta la spazzatura del feed realtime (lat=0, lon=0).
  static bool isPlausible(double lat, double lon) =>
      lat > GttConfig.bboxMinLat &&
      lat < GttConfig.bboxMaxLat &&
      lon > GttConfig.bboxMinLon &&
      lon < GttConfig.bboxMaxLon;
}

/// Punto in metri nel piano locale. Volutamente distinto da una coppia
/// lat/lon, cosi' il compilatore impedisce di confonderli.
class Point {
  const Point(this.x, this.y);

  final double x;
  final double y;

  double distanceTo(Point other) =>
      math.sqrt(math.pow(x - other.x, 2) + math.pow(y - other.y, 2));

  @override
  String toString() => 'Point(${x.toStringAsFixed(1)}, ${y.toStringAsFixed(1)})';

  @override
  bool operator ==(Object other) =>
      other is Point && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);
}

/// Coordinata geografica. E' il tipo che entra ed esce dal sistema;
/// dentro si lavora sempre in [Point].
class GeoPoint {
  const GeoPoint(this.lat, this.lon);

  final double lat;
  final double lon;

  Point get meters => Projection.toMeters(lat, lon);

  bool get isPlausible => Projection.isPlausible(lat, lon);

  @override
  String toString() =>
      '${lat.toStringAsFixed(5)},${lon.toStringAsFixed(5)}';

  @override
  bool operator ==(Object other) =>
      other is GeoPoint && other.lat == lat && other.lon == lon;

  @override
  int get hashCode => Object.hash(lat, lon);
}
