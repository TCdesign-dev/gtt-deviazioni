import 'projection.dart';

/// Codifica Google Polyline (precisione 5).
///
/// Serve in due punti: le geometrie che restituisce Valhalla e, se un
/// giorno si tornasse a usarlo, l'OTP di GTT. Il GTFS statico invece da'
/// i punti gia' espansi in shapes.txt.
class PolylineCodec {
  const PolylineCodec._();

  static List<GeoPoint> decode(String encoded, {int precision = 5}) {
    final factor = _pow10(precision);
    final points = <GeoPoint>[];
    var index = 0;
    var lat = 0;
    var lon = 0;

    while (index < encoded.length) {
      var shift = 0;
      var result = 0;
      int b;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20 && index < encoded.length);
      lat += (result & 1) != 0 ? ~(result >> 1) : (result >> 1);

      shift = 0;
      result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20 && index < encoded.length);
      lon += (result & 1) != 0 ? ~(result >> 1) : (result >> 1);

      points.add(GeoPoint(lat / factor, lon / factor));
    }
    return points;
  }

  static String encode(List<GeoPoint> points, {int precision = 5}) {
    final factor = _pow10(precision);
    final buffer = StringBuffer();
    var prevLat = 0;
    var prevLon = 0;

    for (final p in points) {
      final lat = (p.lat * factor).round();
      final lon = (p.lon * factor).round();
      _encodeValue(lat - prevLat, buffer);
      _encodeValue(lon - prevLon, buffer);
      prevLat = lat;
      prevLon = lon;
    }
    return buffer.toString();
  }

  static void _encodeValue(int value, StringBuffer out) {
    var v = value < 0 ? ~(value << 1) : (value << 1);
    while (v >= 0x20) {
      out.writeCharCode((0x20 | (v & 0x1f)) + 63);
      v >>= 5;
    }
    out.writeCharCode(v + 63);
  }

  static double _pow10(int n) {
    var r = 1.0;
    for (var i = 0; i < n; i++) {
      r *= 10;
    }
    return r;
  }
}
