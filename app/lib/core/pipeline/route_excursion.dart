import '../geo/geometry.dart';
import '../geo/projection.dart';
import 'vehicle_watch.dart';

/// Dove un mezzo ha lasciato il percorso normale e dove ci è tornato.
///
/// **È l'unica verità che non viene da un testo.** Tutto il resto del
/// sistema parte da come GTT ha scritto l'avviso: l'LLM lo interpreta, il
/// geocoder cerca le vie, Valhalla ricostruisce un percorso plausibile. Qui
/// invece si guardano i mezzi veri. Se le tracce dicono che il bus esce
/// dopo la fermata Sabotino e rientra a San Paolo, quello è successo — non
/// è un'inferenza.
///
/// Serve soprattutto al punto più debole della catena, il **rientro**:
/// MISURATO, 24 avvisi su 28 non lo nominano, e dedurlo dall'ultima via
/// scritta funziona sulla mediana (10 m) ma ha una coda lunga (75° pct
/// 237 m). Una traccia GPS che rientra sul percorso lo dice senza margine.
class RouteExcursion {
  const RouteExcursion({
    required this.vehicleId,
    required this.detachAlongMeters,
    required this.path,
    required this.maxDistanceMeters,
    this.rejoinAlongMeters,
  });

  final String vehicleId;

  /// Dove ha lasciato il percorso, misurato lungo il percorso ufficiale.
  final double detachAlongMeters;

  /// Dove ci è tornato. **null se non è ancora rientrato** entro
  /// l'osservazione: in quel caso non si sa dove rientrerà, e non lo si
  /// inventa.
  final double? rejoinAlongMeters;

  /// I punti fuori percorso, in ordine. È il tratto deviato **reale**.
  final List<GeoPoint> path;

  final double maxDistanceMeters;

  /// L'escursione si è chiusa: il mezzo è rientrato mentre lo guardavamo.
  bool get isComplete => rejoinAlongMeters != null;

  /// Quanto percorso ufficiale salta.
  double? get spanMeters => rejoinAlongMeters == null
      ? null
      : rejoinAlongMeters! - detachAlongMeters;

  @override
  String toString() => isComplete
      ? '$vehicleId: esce a ${detachAlongMeters.round()} m, rientra a '
          '${rejoinAlongMeters!.round()} m (max ${maxDistanceMeters.round()} m)'
      : '$vehicleId: esce a ${detachAlongMeters.round()} m, non ancora '
          'rientrato';

  /// Le escursioni di una traccia rispetto al percorso ufficiale.
  ///
  /// Un'escursione è una sequenza continua di punti oltre soglia. Gli
  /// estremi si prendono dai punti **sul** percorso che la circondano:
  /// proiettare un punto fuori rotta darebbe una posizione senza
  /// significato, perché il piede della perpendicolare può cadere ovunque.
  ///
  /// Un punto isolato fuori soglia non fa un'escursione: il GPS sbaglia, e
  /// MISURATO il 3% delle posizioni è spazzatura. Ne servono almeno due
  /// di fila, la stessa regola di [VehicleTrack.isOffRoute].
  /// [officialRoute] e' il percorso su cui si MISURANO le posizioni: gli
  /// stacchi e i rientri sono metri lungo questo, ed e' l'unico modo di
  /// confrontarli fra loro.
  ///
  /// [allRoutes] sono TUTTE le varianti della linea, e servono a decidere
  /// se un mezzo e' davvero fuori. Un mezzo sulla corsa limitata, o su
  /// una diramazione, e' lontano dal percorso principale ma sta facendo
  /// il suo lavoro: contarlo come deviazione e' il falso positivo che la
  /// specifica (§5.3.2) mette in guardia dal produrre — e che si vede
  /// subito, perche' l'esito direbbe "tutti sul percorso" mentre qui
  /// comparirebbe una deviazione inesistente.
  static List<RouteExcursion> detect({
    required VehicleTrack track,
    required List<Point> officialRoute,
    required double offRouteMeters,
    List<List<Point>>? allRoutes,
    int minConsecutivePoints = 2,
  }) {
    if (officialRoute.length < 2 || track.points.length < 2) return const [];
    final varianti = (allRoutes == null || allRoutes.isEmpty)
        ? [officialRoute]
        : allRoutes;

    // Si ordina per tempo: il feed non garantisce l'ordine, e un'escursione
    // e' per definizione una cosa che ha un prima e un dopo.
    final punti = [...track.points]
      ..sort((a, b) => a.seenAt.compareTo(b.seenAt));

    final fuori = <bool>[];
    final along = <double>[];
    final dist = <double>[];
    for (final o in punti) {
      final p = o.position.meters;
      // La posizione si misura sul percorso principale...
      final proj = Geometry.projectOnPolyline(p, officialRoute);
      // ...ma "e' fuori?" si decide sulla variante piu' vicina.
      var d = double.infinity;
      for (final v in varianti) {
        if (v.length < 2) continue;
        final x = Geometry.pointToPolyline(p, v);
        if (x < d) d = x;
      }
      fuori.add(d > offRouteMeters);
      along.add(proj.alongMeters);
      dist.add(d);
    }

    final out = <RouteExcursion>[];
    var i = 0;
    while (i < punti.length) {
      if (!fuori[i]) {
        i++;
        continue;
      }
      var j = i;
      while (j + 1 < punti.length && fuori[j + 1]) {
        j++;
      }
      final quanti = j - i + 1;
      if (quanti >= minConsecutivePoints) {
        // Lo stacco: l'ultimo punto SUL percorso prima di uscire. Se la
        // traccia comincia gia' fuori, non sappiamo dove sia uscito e si
        // ripiega sulla proiezione del primo punto — approssimata, ma
        // l'alternativa e' non dire niente di un'escursione reale.
        final detach = i > 0 ? along[i - 1] : along[i];
        // Il rientro: il primo punto SUL percorso dopo. Se non c'e', il
        // mezzo non e' ancora rientrato e non si inventa dove lo fara'.
        final rejoin = j + 1 < punti.length ? along[j + 1] : null;

        var max = 0.0;
        for (var k = i; k <= j; k++) {
          if (dist[k] > max) max = dist[k];
        }

        out.add(RouteExcursion(
          vehicleId: track.vehicleId,
          detachAlongMeters: detach,
          rejoinAlongMeters: rejoin,
          path: [for (var k = i; k <= j; k++) punti[k].position],
          maxDistanceMeters: max,
        ));
      }
      i = j + 1;
    }
    return out;
  }
}

/// Quello su cui i mezzi osservati sono d'accordo.
///
/// Un mezzo solo può essere un'anomalia: un guasto, una deviazione per un
/// camion fermo, un rientro in deposito. Due o più che escono e rientrano
/// nello stesso punto sono una deviazione.
class ExcursionConsensus {
  const ExcursionConsensus({
    required this.detachAlongMeters,
    required this.rejoinAlongMeters,
    required this.vehicles,
    required this.path,
  });

  final double detachAlongMeters;

  /// null se nessuno dei mezzi concordi è ancora rientrato.
  final double? rejoinAlongMeters;

  /// Quanti mezzi hanno fatto la stessa cosa.
  final int vehicles;

  /// La traccia più lunga fra quelle concordi: è il tratto deviato reale
  /// meglio campionato che abbiamo.
  final List<GeoPoint> path;

  bool get isSolid => vehicles >= 2;

  /// Mette d'accordo le escursioni di più mezzi.
  ///
  /// [tolleranzaMetri] quanto possono differire i punti di stacco perché
  /// si consideri la stessa deviazione. Le posizioni arrivano ogni ~20 s,
  /// e a 30 km/h sono 170 m fra un punto e l'altro: la tolleranza deve
  /// essere almeno di quell'ordine o due mezzi che fanno la stessa cosa
  /// sembrerebbero farne due diverse.
  static ExcursionConsensus? from(
    List<RouteExcursion> excursions, {
    double tolleranzaMetri = 400,
  }) {
    if (excursions.isEmpty) return null;

    // Si raggruppa per punto di stacco: e' quello noto anche quando il
    // mezzo non e' ancora rientrato.
    final ordinate = [...excursions]
      ..sort((a, b) => a.detachAlongMeters.compareTo(b.detachAlongMeters));

    var migliore = <RouteExcursion>[];
    for (var i = 0; i < ordinate.length; i++) {
      final gruppo = ordinate
          .where((e) =>
              (e.detachAlongMeters - ordinate[i].detachAlongMeters).abs() <=
              tolleranzaMetri)
          .toList();
      // Piu' mezzi d'accordo vince; a parita', il gruppo che parte prima.
      if (gruppo.length > migliore.length) migliore = gruppo;
    }
    if (migliore.isEmpty) return null;

    final mezzi = migliore.map((e) => e.vehicleId).toSet();
    final chiuse = migliore.where((e) => e.isComplete).toList();

    // Lo stacco piu' a monte e il rientro piu' a valle: il tratto
    // interessato e' l'unione di cio' che i mezzi hanno fatto, non
    // l'intersezione. Sbagliare per eccesso qui significa segnalare una
    // fermata in piu' come dubbia; per difetto, dirla servita quando non
    // lo e'.
    final detach = migliore
        .map((e) => e.detachAlongMeters)
        .reduce((a, b) => a < b ? a : b);
    final rejoin = chiuse.isEmpty
        ? null
        : chiuse
            .map((e) => e.rejoinAlongMeters!)
            .reduce((a, b) => a > b ? a : b);

    final piuLunga = migliore
        .reduce((a, b) => a.path.length >= b.path.length ? a : b);

    return ExcursionConsensus(
      detachAlongMeters: detach,
      rejoinAlongMeters: rejoin,
      vehicles: mezzi.length,
      path: piuLunga.path,
    );
  }
}
