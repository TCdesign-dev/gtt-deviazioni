import 'dart:async';

import '../config.dart';
import '../geo/geometry.dart';
import '../geo/projection.dart';
import '../models/transit.dart';
import '../sources/vehicles_source.dart';

/// Cosa dicono i mezzi.
enum WatchOutcome {
  /// Mezzi osservati, tutti sul percorso normale.
  ///
  /// Se GTT dichiara una deviazione, questo e' l'indizio migliore che sia
  /// **finita**: la specifica (§10.13) segnala che GTT annuncia quasi
  /// sempre l'inizio e quasi mai la fine.
  tuttiSulPercorso,

  /// Mezzi fuori dal percorso normale: la deviazione e' in corso.
  fuoriPercorso,

  /// Nessun mezzo osservato.
  ///
  /// **NON significa "va tutto bene".** Di notte, o su una linea a bassa
  /// frequenza, non c'e' semplicemente nulla da guardare. Confonderlo con
  /// "tutto regolare" direbbe all'utente una cosa che non sappiamo.
  nessunMezzo,

  /// Mezzi visti ma troppo pochi punti per dire qualcosa.
  inconcludente,

  /// GTT non sta pubblicando le posizioni di NESSUN mezzo.
  ///
  /// Diverso da [nessunMezzo], e la differenza non e' accademica:
  /// MISURATO, dopo le 23:30 il feed torna vuoto mentre il servizio
  /// continua — la linea 15 ha corse programmate fino alle 01:52. Dire
  /// "nessun mezzo in circolazione" sarebbe falso.
  feedSpento,
}

/// Un mezzo osservato piu' volte, con la sua distanza dal percorso.
class VehicleTrack {
  VehicleTrack(this.vehicleId);

  final String vehicleId;
  final List<VehicleObservation> points = [];

  /// Distanza massima dal percorso teorico piu' vicino, in metri.
  double maxDistanceFromRoute = 0;

  /// Quanti punti stanno oltre la soglia di fuori-rotta.
  int offRoutePoints = 0;

  bool get isOffRoute => offRoutePoints >= 2;

  @override
  String toString() =>
      '$vehicleId: ${points.length} punti, max ${maxDistanceFromRoute.round()} m';
}

class WatchResult {
  const WatchResult({
    required this.outcome,
    required this.tracks,
    required this.observed,
    required this.samples,
  });

  final WatchOutcome outcome;
  final List<VehicleTrack> tracks;
  final Duration observed;
  final int samples;

  int get vehiclesSeen => tracks.length;
  List<VehicleTrack> get offRoute =>
      tracks.where((t) => t.isOffRoute).toList(growable: false);

  double get maxDistance => tracks.isEmpty
      ? 0
      : tracks.map((t) => t.maxDistanceFromRoute).reduce((a, b) => a > b ? a : b);

  /// Come si dice a una persona, senza gerghi.
  String get summary => switch (outcome) {
        WatchOutcome.feedSpento =>
          'GTT non sta pubblicando le posizioni dei mezzi in questo momento. '
              'Succede di notte, anche quando le corse continuano: non posso '
              'guardare, ma non vuol dire che il servizio sia finito.',
        WatchOutcome.nessunMezzo =>
          'Nessun mezzo di questa linea è in circolazione adesso, mentre '
              'altre linee ne hanno: non posso dire nulla sulla deviazione.',
        WatchOutcome.inconcludente =>
          'Ho visto $vehiclesSeen ${vehiclesSeen == 1 ? "mezzo" : "mezzi"} '
              'ma per troppo poco tempo per trarne una conclusione.',
        WatchOutcome.tuttiSulPercorso =>
          '$vehiclesSeen ${vehiclesSeen == 1 ? "mezzo segue" : "mezzi seguono"} '
              'il percorso normale.',
        WatchOutcome.fuoriPercorso =>
          '${offRoute.length} su $vehiclesSeen '
              '${vehiclesSeen == 1 ? "mezzo è" : "mezzi sono"} fuori dal '
              'percorso normale, fino a ${maxDistance.round()} m di distanza.',
      };
}

/// Guarda dove sono davvero i mezzi di una linea, per qualche minuto.
///
/// Non e' il monitoraggio continuo della specifica (§5.3): quello vuole
/// polling perenne, storage e clustering, ed e' la parte col rapporto
/// sforzo/beneficio peggiore. Questa e' una finestra breve **su richiesta**,
/// che risponde a due domande diverse:
///
/// - una deviazione annunciata e' davvero in corso? (conferma)
/// - una deviazione annunciata e' gia' finita? (§10.13, il problema che
///   nessun'altra fonte risolve, perche' GTT la fine non la annuncia)
///
/// Sulla soglia: MISURATO su 349 mezzi, la distanza dal percorso teorico ha
/// mediana 3,6 m e 99° percentile 28 m, una volta scartate le posizioni
/// spazzatura. La specifica proponeva 80 m per prudenza; 50 m lasciano gia'
/// un margine molto ampio.
class VehicleWatch {
  VehicleWatch({
    VehiclesSource? source,
    this.pollInterval = GttConfig.burstPollInterval,
    this.maxDuration = GttConfig.burstMaxDuration,
    this.minVehicles = GttConfig.burstMinVehicles,
    this.offRouteMeters = GttConfig.offRouteMeters,
  }) : _source = source ?? VehiclesSource();

  final VehiclesSource _source;
  final Duration pollInterval;
  final Duration maxDuration;
  final int minVehicles;
  final double offRouteMeters;

  /// Dopo quanti campioni a vuoto si smette di provare.
  static const _givUpAfterEmptySamples = 3;

  /// Osserva i mezzi di [line] confrontandoli con TUTTE le sue varianti di
  /// percorso, non solo la principale.
  ///
  /// Un mezzo che sta facendo la corsa limitata, o che rientra in deposito
  /// su una variante diversa, sembrerebbe altrimenti "fuori rotta" — ed e'
  /// esattamente il falso positivo che §5.3.2 mette in guardia dal
  /// produrre.
  Future<WatchResult> watch({
    required TransitLine line,
    required List<RouteShape> shapes,
    void Function(int samples, int vehicles)? onProgress,
  }) async {
    final started = DateTime.now();
    final tracks = <String, VehicleTrack>{};
    final routes = shapes
        .where((s) => s.points.length > 1)
        .map((s) => s.meters)
        .toList(growable: false);
    var samples = 0;

    var feedWasOff = true;

    while (DateTime.now().difference(started) < maxDuration) {
      VehicleSnapshot snapshot;
      try {
        snapshot = await _source.fetch(routeId: line.routeId);
      } on Object {
        // Un campione perso non e' un fallimento: si riprova al prossimo.
        snapshot = const VehicleSnapshot(matching: [], totalInFeed: 0);
      }
      samples++;
      // Basta un campione con qualcosa dentro per sapere che il feed va.
      if (!snapshot.feedIsOff) feedWasOff = false;

      for (final o in snapshot.matching) {
        final track = tracks.putIfAbsent(o.vehicleId, () => VehicleTrack(o.vehicleId));
        // Lo stesso timestamp ripetuto non e' un punto nuovo: il feed si
        // aggiorna ogni ~20 s, il polling puo' essere piu' fitto.
        if (track.points.any((p) => p.seenAt == o.seenAt)) continue;
        track.points.add(o);

        if (routes.isNotEmpty) {
          final d = _distanceToNearestRoute(o.position, routes);
          if (d > track.maxDistanceFromRoute) track.maxDistanceFromRoute = d;
          if (d > offRouteMeters) track.offRoutePoints++;
        }
      }

      onProgress?.call(samples, tracks.length);

      if (_enough(tracks.values)) break;

      // Se dopo qualche giro non si e' visto NIENTE, la linea non e' in
      // servizio: continuare a interrogare per un quarto d'ora non
      // cambierebbe la risposta e sarebbe scortese verso il feed di GTT.
      if (tracks.isEmpty && samples >= _givUpAfterEmptySamples) break;
      if (DateTime.now().difference(started) + pollInterval >= maxDuration) {
        break;
      }
      await Future<void>.delayed(pollInterval);
    }

    return WatchResult(
      outcome: _classify(tracks.values, feedWasOff: feedWasOff),
      tracks: tracks.values.toList(growable: false),
      observed: DateTime.now().difference(started),
      samples: samples,
    );
  }

  /// Ci si ferma appena si hanno abbastanza mezzi con almeno due punti
  /// ciascuno: aspettare i quindici minuti pieni quando la risposta c'e'
  /// gia' e' solo tempo perso davanti a una rotella che gira.
  bool _enough(Iterable<VehicleTrack> tracks) {
    final usable = tracks.where((t) => t.points.length >= 2).length;
    return usable >= minVehicles;
  }

  WatchOutcome _classify(Iterable<VehicleTrack> tracks,
      {required bool feedWasOff}) {
    // L'ordine conta: un feed spento non e' assenza di mezzi.
    if (tracks.isEmpty && feedWasOff) return WatchOutcome.feedSpento;
    if (tracks.isEmpty) return WatchOutcome.nessunMezzo;
    final usable = tracks.where((t) => t.points.length >= 2).toList();
    if (usable.isEmpty) return WatchOutcome.inconcludente;
    return usable.any((t) => t.isOffRoute)
        ? WatchOutcome.fuoriPercorso
        : WatchOutcome.tuttiSulPercorso;
  }

  static double _distanceToNearestRoute(GeoPoint p, List<List<Point>> routes) {
    final m = p.meters;
    var best = double.infinity;
    for (final r in routes) {
      final d = Geometry.pointToPolyline(m, r);
      if (d < best) best = d;
    }
    return best;
  }
}
