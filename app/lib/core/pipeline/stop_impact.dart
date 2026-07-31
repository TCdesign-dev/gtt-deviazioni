import '../config.dart';
import '../geo/geometry.dart';
import '../geo/projection.dart';
import '../models/transit.dart';

/// Cosa succede a una fermata quando la linea devia.
enum StopStatus {
  /// Il percorso deviato le passa comunque accanto.
  served,

  /// Il percorso deviato non la tocca: dedotto dalla geometria.
  skipped,

  /// GTT ha dichiarato esplicitamente che e' sospesa.
  ///
  /// Questo caso VINCE sempre sulla geometria (§6.1): passare accanto a una
  /// fermata non significa fermarcisi, e se GTT lo dice, lo sa meglio di un
  /// calcolo di distanze.
  declaredSuspended,
}

class StopAlternative {
  const StopAlternative({
    required this.stop,
    required this.straightMeters,
    required this.sameLine,
    this.walkingMeters,
    this.walkingSeconds,
  });

  final TransitStop stop;

  /// Distanza in linea d'aria. Serve a scegliere i candidati, NON a dirla
  /// all'utente: a Torino un fiume o una ferrovia cambiano tutto (§6.1).
  final double straightMeters;

  /// Distanza a piedi reale. null finche' non la si calcola col routing
  /// pedonale, che costa una chiamata di rete per alternativa.
  final double? walkingMeters;
  final int? walkingSeconds;

  /// L'alternativa e' servita dalla stessa linea? Se si', l'utente non deve
  /// cambiare mezzo, ed e' quasi sempre la proposta migliore.
  final bool sameLine;

  /// Quello che si puo' dire all'utente senza mentire.
  double get bestKnownMeters => walkingMeters ?? straightMeters;

  @override
  String toString() => '${stop.name}'
      '${sameLine ? " (stessa linea)" : ""} '
      '${walkingMeters != null ? "${walkingMeters!.round()} m a piedi" : "~${straightMeters.round()} m in linea d'aria"}';
}

class StopImpact {
  const StopImpact({
    required this.stop,
    required this.status,
    this.metersFromDeviatedRoute,
    this.alternatives = const [],
  });

  final TransitStop stop;
  final StopStatus status;
  final double? metersFromDeviatedRoute;
  final List<StopAlternative> alternatives;

  bool get isSkipped => status != StopStatus.served;

  @override
  String toString() => switch (status) {
        StopStatus.served => 'SERVITA   ${stop.name}',
        StopStatus.skipped =>
          'SALTATA   ${stop.name} (${metersFromDeviatedRoute?.round()} m dal '
              'percorso deviato)',
        StopStatus.declaredSuspended =>
          'SOSPESA   ${stop.name} — dichiarata da GTT',
      };
}

class StopImpactResult {
  const StopImpactResult({
    required this.impacts,
    required this.affectedFromMeters,
    required this.affectedToMeters,
  });

  /// Solo le fermate nel tratto interessato dalla deviazione.
  final List<StopImpact> impacts;

  /// Da dove a dove, lungo il percorso ufficiale, la deviazione ha effetto.
  final double affectedFromMeters;
  final double affectedToMeters;

  List<StopImpact> get skipped =>
      impacts.where((i) => i.isSkipped).toList(growable: false);

  List<StopImpact> get served => impacts
      .where((i) => i.status == StopStatus.served)
      .toList(growable: false);

  bool get hasImpact => skipped.isNotEmpty;

  @override
  String toString() =>
      '${skipped.length} fermate non servite su ${impacts.length} nel tratto';
}

/// Quali fermate saltano, e dove andare al loro posto.
///
/// E' l'output che la specifica indica come il piu' utile in assoluto
/// (§6.1) e quello che GTT non da' quasi mai: l'utente sta a una fermata,
/// non su una via, e la domanda che si fa e' "passa ancora di qui?".
class StopImpactAnalyzer {
  const StopImpactAnalyzer({required this.index});

  final GtfsIndex index;

  /// [deviatedRoute] copre SOLO il tratto deviato, non l'intera linea.
  ///
  /// Da qui la parte delicata: non si puo' misurare la distanza di ogni
  /// fermata dal percorso deviato, perche' una fermata a chilometri di
  /// distanza risulterebbe "saltata" solo per non essere nel tratto.
  /// Prima si stabilisce **quale porzione di linea e' interessata**,
  /// proiettando gli estremi della deviazione sul percorso ufficiale, e si
  /// valutano solo le fermate che ci cadono dentro.
  StopImpactResult analyze({
    required RouteShape officialRoute,
    required List<GeoPoint> deviatedRoute,
    Set<String> declaredSuspendedCodes = const {},
  }) {
    final official = officialRoute.meters;
    final deviated = deviatedRoute.map((p) => p.meters).toList();

    if (official.length < 2 || deviated.length < 2) {
      return const StopImpactResult(
          impacts: [], affectedFromMeters: 0, affectedToMeters: 0);
    }

    final startAlong =
        Geometry.projectOnPolyline(deviated.first, official).alongMeters;
    final endAlong =
        Geometry.projectOnPolyline(deviated.last, official).alongMeters;
    final from = startAlong <= endAlong ? startAlong : endAlong;
    final to = startAlong <= endAlong ? endAlong : startAlong;

    final impacts = <StopImpact>[];
    for (final stop in officialRoute.stops) {
      final p = stop.position.meters;
      final along = Geometry.projectOnPolyline(p, official).alongMeters;
      if (along < from || along > to) continue; // fuori dal tratto deviato

      // La dichiarazione esplicita di GTT batte la geometria.
      if (stop.code != null && declaredSuspendedCodes.contains(stop.code)) {
        impacts.add(StopImpact(
          stop: stop,
          status: StopStatus.declaredSuspended,
          metersFromDeviatedRoute: Geometry.pointToPolyline(p, deviated),
          alternatives: _alternativesFor(stop, officialRoute, deviated),
        ));
        continue;
      }

      final distance = Geometry.pointToPolyline(p, deviated);
      if (distance > GttConfig.stopSkippedMeters) {
        impacts.add(StopImpact(
          stop: stop,
          status: StopStatus.skipped,
          metersFromDeviatedRoute: distance,
          alternatives: _alternativesFor(stop, officialRoute, deviated),
        ));
      } else {
        impacts.add(StopImpact(
          stop: stop,
          status: StopStatus.served,
          metersFromDeviatedRoute: distance,
        ));
      }
    }

    return StopImpactResult(
      impacts: impacts,
      affectedFromMeters: from,
      affectedToMeters: to,
    );
  }

  /// Dove puo' andare chi usava una fermata saltata.
  ///
  /// Ordine di preferenza: prima le fermate ancora servite dalla STESSA
  /// linea, cosi' non deve cambiare mezzo; poi le altre entro il raggio.
  List<StopAlternative> _alternativesFor(
    TransitStop skipped,
    RouteShape officialRoute,
    List<Point> deviatedRoute,
  ) {
    final nearby = index.stopsNear(skipped.position,
        radiusMeters: GttConfig.alternativeStopMeters);

    final sameLineIds = officialRoute.stops.map((s) => s.id).toSet();
    final out = <StopAlternative>[];

    for (final n in nearby) {
      if (n.stop.id == skipped.id) continue;

      final onSameLine = sameLineIds.contains(n.stop.id);
      // Una fermata della stessa linea vale come alternativa solo se il
      // percorso deviato ci passa davvero accanto: altrimenti e' saltata
      // anche lei e mandarci l'utente sarebbe un errore.
      if (onSameLine) {
        final d = Geometry.pointToPolyline(n.stop.position.meters, deviatedRoute);
        if (d > GttConfig.stopSkippedMeters) continue;
      }

      out.add(StopAlternative(
        stop: n.stop,
        straightMeters: n.meters,
        sameLine: onSameLine,
      ));
    }

    // Prima quelle della stessa linea, poi per distanza crescente.
    out.sort((a, b) {
      if (a.sameLine != b.sameLine) return a.sameLine ? -1 : 1;
      return a.straightMeters.compareTo(b.straightMeters);
    });
    return out.take(3).toList(growable: false);
  }
}
