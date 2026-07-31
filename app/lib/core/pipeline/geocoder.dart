import 'dart:convert';

import '../config.dart';
import '../geo/geometry.dart';
import '../geo/projection.dart';
import '../models/transit.dart';
import '../net/gtt_http.dart';

/// Da un nome di via al punto sulla mappa, **vincolato al percorso della
/// linea**.
///
/// E' il passaggio che aveva fatto fallire il tentativo precedente
/// (§5.2.2): "via Ferrero" cercata liberamente restituisce una via a caso
/// in Italia. La correzione e' cercare solo attorno al percorso reale
/// della linea, che qui si conosce al metro dal GTFS.
///
/// MISURATO il 31/07/2026 sui 150 toponimi di 34 avvisi annotati a mano:
/// 150 su 150 risolti entro 2 km dal percorso, 142 entro 500 m. Come
/// controllo, vie di Torino estranee alla linea 55 finiscono a 1342-6446 m,
/// mentre i toponimi veri stanno entro 230 m: il vincolo discrimina
/// davvero, non promuove tutto.
///
/// Da qui la taratura di [GttConfig.geocodeBufferMeters] a 1 km invece dei
/// 2 km della specifica: a 2 km passa spazzatura, a 500 m si scartano vie
/// legittime, perche' una deviazione per definizione si allontana dal
/// percorso normale.
class Geocoder {
  Geocoder({GttHttp? http, double? bufferMeters})
      : _http = http ?? GttHttp(),
        bufferMeters = bufferMeters ?? GttConfig.geocodeBufferMeters;

  final GttHttp _http;

  /// Quanto lontano dal percorso puo' stare un risultato per essere
  /// considerato quello giusto.
  final double bufferMeters;

  /// Le deviazioni citano piu' volte la stessa via (andata e ritorno):
  /// senza cache si interrogherebbe Photon due volte per nulla, e Photon
  /// e' un servizio pubblico gratuito.
  final Map<String, GeocodeResult> _cache = {};

  /// Cerca [toponym] vicino a [near]. [municipality] viene dall'avviso
  /// ("Nel Comune di Chieri"): e' un'informazione che GTT regala e che
  /// disambigua le decine di "via Roma" dell'area metropolitana (§10.7).
  Future<GeocodeResult> locate(
    String toponym, {
    required RouteShape near,
    String? municipality,
  }) async {
    final cleaned = normalizeToponym(toponym);
    final key = '$cleaned|${municipality ?? ""}|${near.shapeId}';
    final cached = _cache[key];
    if (cached != null) return cached;

    final result = await _lookup(cleaned, toponym, near, municipality);
    _cache[key] = result;
    return result;
  }

  Future<GeocodeResult> _lookup(
    String cleaned,
    String original,
    RouteShape near,
    String? municipality,
  ) async {
    final centre = near.centroid;
    final query = municipality == null || municipality.isEmpty
        ? cleaned
        : '$cleaned, $municipality';

    final uri = Uri.parse(GttConfig.photonUrl).replace(queryParameters: {
      'q': query,
      'lat': centre.lat.toString(),
      'lon': centre.lon.toString(),
      'limit': '5',
      // MAI lang=it: Photon supporta solo default/de/en/fr e risponde 400.
      // Senza controllare lo status il fallimento sembra "nessun
      // risultato" invece di "richiesta sbagliata" — ci ho perso un giro.
    });

    final String body;
    try {
      body = await _http.getTextPolite(uri.toString());
    } on GttHttpException catch (e) {
      return GeocodeResult.error(original, e.toString());
    }

    final Map<String, dynamic> json;
    try {
      json = jsonDecode(body) as Map<String, dynamic>;
    } on Object catch (e) {
      return GeocodeResult.error(original, 'risposta non JSON: $e');
    }

    final features = (json['features'] as List?) ?? const [];
    if (features.isEmpty) {
      return GeocodeResult.notFound(original);
    }

    // Fra i candidati si prende il piu' vicino al percorso, non il primo:
    // Photon ordina per rilevanza testuale, a noi serve quello giusto
    // geograficamente.
    GeocodeResult? best;
    for (final f in features) {
      final feature = f as Map<String, dynamic>;
      final coords =
          (feature['geometry'] as Map<String, dynamic>?)?['coordinates'];
      if (coords is! List || coords.length < 2) continue;
      final point = GeoPoint(
          (coords[1] as num).toDouble(), (coords[0] as num).toDouble());
      final props = (feature['properties'] as Map<String, dynamic>?) ?? {};
      final distance =
          Geometry.pointToPolyline(point.meters, near.meters);

      if (best == null || distance < best.metersFromRoute!) {
        best = GeocodeResult(
          status: distance <= bufferMeters
              ? GeocodeStatus.ok
              : GeocodeStatus.outsideBuffer,
          query: original,
          point: point,
          osmName: props['name'] as String?,
          municipality: props['city'] as String?,
          metersFromRoute: distance,
        );
      }
    }

    return best ?? GeocodeResult.notFound(original);
  }

  /// Normalizza le abbreviazioni e i caratteri che GTT usa in modo
  /// incoerente (§5.2.2, §10.12).
  ///
  /// L'apostrofo tipografico U+2019 contro quello dritto e' la trappola
  /// numero 12 della specifica, e compare davvero: "corso Massimo
  /// d'Azeglio", "via dell'Arsenale".
  static String normalizeToponym(String raw) {
    var s = raw.trim();

    // Apostrofi e spazi non separabili.
    s = s
        .replaceAll('’', "'")
        .replaceAll('‘', "'")
        .replaceAll(' ', ' ');

    // Abbreviazioni: c.so -> corso, p.zza -> piazza, v.le -> viale...
    //
    // ATTENZIONE alle abbreviazioni che finiscono col punto: NON metterci
    // \b in coda. Il confine di parola richiede il passaggio fra un
    // carattere alfanumerico e uno che non lo e', ma dopo il punto viene
    // uno spazio — entrambi non alfanumerici, quindi nessun confine e la
    // sostituzione non avviene mai, in silenzio. "str. del Drosso"
    // restava tale e quale.
    const abbreviations = {
      r'\bc\.so\b': 'corso',
      r'\bc\.rso\b': 'corso',
      r'\bp\.zza\b': 'piazza',
      r'\bp\.za\b': 'piazza',
      r'\bpza\b': 'piazza',
      r'\bv\.le\b': 'viale',
      r'\bstr\.': 'strada',
      r'\blgo\b': 'largo',
      r'\bs\.p\.': 'strada provinciale',
      r'\bsp\.': 'strada provinciale',
    };
    abbreviations.forEach((pattern, full) {
      s = s.replaceAll(RegExp(pattern, caseSensitive: false), full);
    });

    return s.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  void clearCache() => _cache.clear();
}

enum GeocodeStatus {
  /// Trovato ed entro il vincolo: usabile.
  ok,

  /// Trovato ma troppo lontano dal percorso. Con ogni probabilita' e' una
  /// via omonima altrove: NON va usata.
  outsideBuffer,

  /// Photon non conosce questo nome.
  notFound,

  /// Rete o servizio in errore. Diverso da [notFound]: qui non sappiamo,
  /// e ritentare puo' avere senso.
  error,
}

/// Esito di una geocodifica.
///
/// Porta con se' anche i casi negativi e il perche': la regola di §12.5 e'
/// che il sistema deve dichiarare incertezza, mai produrre una geometria
/// inventata. Un'informazione mancante e' recuperabile, una sbagliata fa
/// perdere il bus.
class GeocodeResult {
  const GeocodeResult({
    required this.status,
    required this.query,
    this.point,
    this.osmName,
    this.municipality,
    this.metersFromRoute,
    this.detail,
  });

  factory GeocodeResult.notFound(String query) =>
      GeocodeResult(status: GeocodeStatus.notFound, query: query);

  factory GeocodeResult.error(String query, String detail) => GeocodeResult(
      status: GeocodeStatus.error, query: query, detail: detail);

  final GeocodeStatus status;

  /// Il toponimo cosi' come l'ha scritto GTT.
  final String query;

  final GeoPoint? point;

  /// Come si chiama in OSM: spesso piu' lungo di come lo scrive GTT
  /// ("via Asinari di Bernezzo" -> "Via Vittorio Asinari di Bernezzo").
  /// Utile da mostrare quando si chiede conferma all'utente.
  final String? osmName;

  final String? municipality;
  final double? metersFromRoute;
  final String? detail;

  bool get isUsable => status == GeocodeStatus.ok;

  @override
  String toString() {
    switch (status) {
      case GeocodeStatus.ok:
        return 'OK "$query" -> $osmName a '
            '${metersFromRoute!.toStringAsFixed(0)} m dal percorso';
      case GeocodeStatus.outsideBuffer:
        return 'FUORI VINCOLO "$query" -> $osmName a '
            '${metersFromRoute!.toStringAsFixed(0)} m: probabile omonima';
      case GeocodeStatus.notFound:
        return 'NON TROVATO "$query"';
      case GeocodeStatus.error:
        return 'ERRORE "$query": $detail';
    }
  }
}
