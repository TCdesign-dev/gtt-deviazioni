import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../core/deviation_service.dart';
import '../core/models/transit.dart';
import '../core/geo/projection.dart';
import '../core/pipeline/stop_impact.dart';
import '../core/pipeline/vehicle_watch.dart';
import '../data/user_location.dart';

/// La mappa della linea: percorso normale, deviazioni, e le fermate.
///
/// Si mostra SEMPRE, anche quando nessuna deviazione e' stata ricostruita.
/// Vedere dove passa la linea e dove si sale e' utile comunque, e
/// nasconderla proprio quando il testo non si e' capito lascia l'utente
/// senza nulla in mano nel momento peggiore.
///
/// Convenzioni grafiche dalla specifica §6.2: percorso normale sottile e
/// grigio, tratto deviato rosso e spesso, fermate saltate cerchiate.
class LineMap extends StatefulWidget {
  const LineMap({
    required this.status,
    super.key,
    this.height = 280,
    this.vehicles = const [],
  });

  final LineStatus status;
  final double height;

  /// I mezzi osservati adesso, se un'osservazione e' in corso o appena
  /// conclusa. Si disegnano sopra tutto il resto: sono la cosa che si
  /// muove, ed e' quella che si guarda.
  final List<VehicleTrack> vehicles;

  @override
  State<LineMap> createState() => _LineMapState();
}

class _LineMapState extends State<LineMap> {
  /// Il controller serve solo a centrare la mappa su di te quando lo
  /// chiedi: per il resto la mappa si posiziona da sola sul percorso.
  final _map = MapController();

  final _location = UserLocation();
  StreamSubscription<GeoPoint>? _locationSub;
  GeoPoint? _me;
  bool _locating = false;

  @override
  void dispose() {
    _locationSub?.cancel();
    _location.stop();
    super.dispose();
  }

  /// Il permesso si chiede QUI, quando l'utente tocca il pulsante — non
  /// all'apertura della schermata. Una richiesta che arriva senza che tu
  /// abbia chiesto niente si nega per riflesso, e poi e' finita.
  Future<void> _showMe() async {
    if (_locationSub != null) {
      // Secondo tocco: si smette di seguire.
      await _locationSub?.cancel();
      _locationSub = null;
      setState(() => _me = null);
      return;
    }

    setState(() => _locating = true);
    final denial = await _location.ensurePermission();
    if (!mounted) return;
    if (denial != null) {
      setState(() => _locating = false);
      _say(UserLocation.explain(denial));
      return;
    }

    final first = await _location.current();
    if (!mounted) return;
    setState(() {
      _locating = false;
      _me = first;
    });
    if (first == null) {
      _say(UserLocation.explain(LocationDenial.nessunSegnale));
      return;
    }
    _map.move(LatLng(first.lat, first.lon), 15);

    // Poi il punto continua a seguirti: un pallino fermo dove eri due
    // minuti fa e' peggio che nessun pallino.
    _locationSub = _location.follow().listen((p) {
      if (mounted) setState(() => _me = p);
    }, onError: (_) {});
  }

  void _say(String message) => ScaffoldMessenger.maybeOf(
    context,
  )?.showSnackBar(SnackBar(content: Text(message)));

  /// La fermata toccata. Dei pallini muti non servono a niente: uno tocca
  /// per sapere COME SI CHIAMA quella fermata.
  ({TransitStop stop, StopImpact? impact})? _selected;

  @override
  Widget build(BuildContext context) {
    final status = widget.status;

    // Andata e ritorno sono percorsi diversi e vanno mostrati entrambi:
    // spesso non coincidono, per via dei sensi unici, e una deviazione ne
    // riguarda spesso una sola.
    final directions = status.mainShapes
        .where((s) => s.points.length > 1)
        .map(
          (s) => (
            shape: s,
            points: s.points
                .map((p) => LatLng(p.lat, p.lon))
                .toList(growable: false),
          ),
        )
        .toList();
    if (directions.isEmpty) return const SizedBox.shrink();
    final official = directions.first.points;

    // Solo cio' che e' in corso: disegnare in rosso una deviazione che
    // comincia fra tre settimane farebbe scendere alla fermata sbagliata
    // oggi.
    final deviations = status.activeReports
        .where((r) => r.hasMap)
        .map(
          (r) => r.deviatedGeometry!
              .map((p) => LatLng(p.lat, p.lon))
              .toList(growable: false),
        )
        .toList();

    // Le fermate saltate hanno la precedenza: se una fermata e' saltata
    // non va disegnata anche come servita.
    final skipped = {for (final s in status.allSkippedStops) s.stop.id: s};
    // Le fermate di TUTTE le direzioni, senza doppioni: molte sono in
    // comune fra andata e ritorno (banchine opposte hanno id diversi).
    final served = {
      for (final d in directions)
        for (final s in d.shape.stops)
          if (!skipped.containsKey(s.id)) s.id: s,
    }.values.toList(growable: false);

    final bounds = LatLngBounds.fromPoints(
      deviations.isNotEmpty
          ? deviations.expand((d) => d).toList()
          : directions.expand((d) => d.points).toList(),
    );

    return Column(
      children: [
        SizedBox(
          height: widget.height,
          child: Stack(
            children: [
              FlutterMap(
                mapController: _map,
                options: MapOptions(
                  initialCameraFit: CameraFit.bounds(
                    bounds: bounds,
                    padding: const EdgeInsets.all(28),
                  ),
                  interactionOptions: const InteractionOptions(
                    flags:
                        InteractiveFlag.pinchZoom |
                        InteractiveFlag.drag |
                        InteractiveFlag.doubleTapZoom,
                  ),
                  onTap: (_, _) => setState(() => _selected = null),
                ),
                children: [
                  TileLayer(
                    urlTemplate:
                        'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'dev.tcdesign.gtt_deviazioni',
                  ),
                  PolylineLayer(
                    polylines: [
                      // Le due direzioni con tonalita' diverse: dove i
                      // percorsi divergono si deve poter capire quale e' quale.
                      for (var i = 0; i < directions.length; i++)
                        Polyline(
                          points: directions[i].points,
                          strokeWidth: 4,
                          color: (i == 0 ? Colors.blueGrey : Colors.teal)
                              .withValues(alpha: 0.55),
                        ),
                      for (final d in deviations)
                        Polyline(
                          points: d,
                          strokeWidth: 6,
                          color: Colors.red.shade700,
                        ),
                    ],
                  ),
                  // Le fermate servite: piccole e discrete, non devono coprire
                  // il percorso.
                  MarkerLayer(
                    markers: [
                      for (final s in served)
                        _stopMarker(
                          stop: s,
                          impact: null,
                          selected: _selected?.stop.id == s.id,
                        ),
                    ],
                  ),
                  // Le saltate sopra, piu' grandi: sono quelle che contano.
                  MarkerLayer(
                    markers: [
                      for (final entry in skipped.entries)
                        _stopMarker(
                          stop: entry.value.stop,
                          impact: entry.value,
                          selected: _selected?.stop.id == entry.key,
                        ),
                    ],
                  ),
                  MarkerLayer(
                    markers: [
                      _endMarker(official.first, Colors.green.shade700),
                      _endMarker(official.last, Colors.blueGrey.shade700),
                    ],
                  ),
                  // I mezzi, sopra a tutto.
                  if (widget.vehicles.isNotEmpty)
                    MarkerLayer(
                      markers: [
                        for (final t in widget.vehicles)
                          if (t.points.isNotEmpty) _vehicleMarker(t),
                      ],
                    ),
                  if (_me != null) MarkerLayer(markers: [_meMarker(_me!)]),
                  const RichAttributionWidget(
                    alignment: AttributionAlignment.bottomLeft,
                    attributions: [TextSourceAttribution('OpenStreetMap')],
                  ),
                ],
              ),
              Positioned(
                right: 10,
                bottom: 10,
                child: _LocateButton(
                  active: _locationSub != null,
                  busy: _locating,
                  onPressed: _showMe,
                ),
              ),
            ],
          ),
        ),
        if (_selected != null)
          _SelectedStopBanner(
            stop: _selected!.stop,
            impact: _selected!.impact,
            onClose: () => setState(() => _selected = null),
          )
        else
          _Legend(
            hasDeviation: deviations.isNotEmpty,
            // Nessuna geometria ma delle fermate saltate: puo' succedere
            // solo quando GTT ha nominato le fermate sospese senza
            // annunciare un cambio di percorso. Dire "non ricostruita"
            // sarebbe una bugia — non c'era niente da ricostruire.
            onlySuspendedStops: deviations.isEmpty && skipped.isNotEmpty,
            skippedCount: skipped.length,
            servedCount: served.length,
            vehicleCount: widget.vehicles.length,
            vehiclesSeenAt: _lastSeen,
            directions: [for (final d in directions) d.shape.headsign],
          ),
      ],
    );
  }

  Marker _stopMarker({
    required TransitStop stop,
    required StopImpact? impact,
    required bool selected,
  }) {
    final isSkipped = impact != null;
    final dot = isSkipped ? 20.0 : (selected ? 16.0 : 11.0);

    // Il pallino visibile e' piccolo, ma il Marker di flutter_map usa le
    // proprie dimensioni ANCHE come area sensibile al tocco: con 11 px non
    // si prende mai. Il marcatore e' quindi grande [_tapTarget] con il
    // pallino centrato dentro. Verificato sul simulatore: prima il tocco
    // mancava il bersaglio quasi sempre.
    return Marker(
      point: LatLng(stop.position.lat, stop.position.lon),
      width: _tapTarget,
      height: _tapTarget,
      child: GestureDetector(
        onTap: () => setState(() => _selected = (stop: stop, impact: impact)),
        behavior: HitTestBehavior.opaque,
        child: Center(
          child: Container(
            width: dot,
            height: dot,
            decoration: BoxDecoration(
              color: isSkipped
                  ? Theme.of(context).colorScheme.error
                  : Colors.white,
              shape: BoxShape.circle,
              border: Border.all(
                color: isSkipped
                    ? Colors.white
                    : (selected
                          ? Theme.of(context).colorScheme.primary
                          : Colors.blueGrey.shade600),
                width: selected || isSkipped ? 3 : 2,
              ),
            ),
            child: isSkipped
                ? const Icon(Icons.close, size: 11, color: Colors.white)
                : null,
          ),
        ),
      ),
    );
  }

  /// Lato dell'area toccabile di una fermata. Le linee guida Apple
  /// chiedono almeno 44 pt; qui si sta piu' bassi perche' le fermate sono
  /// vicine fra loro e bersagli enormi si ruberebbero i tocchi a vicenda.
  static const _tapTarget = 34.0;

  /// Quando risale l'ultima posizione ricevuta.
  ///
  /// A osservazione finita i marcatori restano sulla mappa: senza dire
  /// quando sono stati visti, dopo dieci minuti si guarderebbero posizioni
  /// vecchie credendole attuali.
  DateTime? get _lastSeen {
    DateTime? latest;
    for (final t in widget.vehicles) {
      for (final p in t.points) {
        if (latest == null || p.seenAt.isAfter(latest)) latest = p.seenAt;
      }
    }
    return latest;
  }

  /// Un mezzo nella sua ultima posizione nota.
  ///
  /// Quelli fuori percorso sono rossi: e' l'informazione che si sta
  /// cercando quando si accende l'osservazione.
  /// Il pallino azzurro. Deliberatamente diverso dalle fermate e dai
  /// mezzi: e' l'unica cosa sulla mappa che non viene da GTT.
  Marker _meMarker(GeoPoint p) => Marker(
    point: LatLng(p.lat, p.lon),
    width: 26,
    height: 26,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.blue.shade600,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 3),
        boxShadow: [
          BoxShadow(
            color: Colors.blue.withValues(alpha: 0.4),
            blurRadius: 8,
            spreadRadius: 2,
          ),
        ],
      ),
    ),
  );

  Marker _vehicleMarker(VehicleTrack track) {
    final last = track.points.last;
    final off = track.isOffRoute;
    return Marker(
      point: LatLng(last.position.lat, last.position.lon),
      width: 26,
      height: 26,
      child: Container(
        decoration: BoxDecoration(
          color: off
              ? Theme.of(context).colorScheme.error
              : Colors.blue.shade700,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2),
          boxShadow: const [
            BoxShadow(
              color: Colors.black26,
              blurRadius: 3,
              offset: Offset(0, 1),
            ),
          ],
        ),
        child: const Icon(Icons.directions_bus, size: 14, color: Colors.white),
      ),
    );
  }

  static Marker _endMarker(LatLng at, Color colour) => Marker(
    point: at,
    width: 14,
    height: 14,
    child: Container(
      decoration: BoxDecoration(
        color: colour,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2),
      ),
    ),
  );
}

/// Cosa si e' toccato. Sostituisce la legenda mentre e' aperto: sono
/// entrambe righe di servizio sotto la mappa, e averle insieme fa
/// disordine.
class _SelectedStopBanner extends StatelessWidget {
  const _SelectedStopBanner({
    required this.stop,
    required this.impact,
    required this.onClose,
  });

  final TransitStop stop;
  final StopImpact? impact;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final skipped = impact != null;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      color: skipped
          ? scheme.errorContainer.withValues(alpha: 0.5)
          : scheme.surfaceContainerHighest.withValues(alpha: 0.5),
      child: Row(
        children: [
          Icon(
            skipped ? Icons.do_not_disturb_on_outlined : Icons.place_outlined,
            size: 18,
            color: skipped ? scheme.error : scheme.primary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  stop.name,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                Text(
                  skipped
                      ? (impact!.status == StopStatus.declaredSuspended
                            ? 'sospesa da GTT'
                            : 'non servita durante la deviazione')
                      : 'servita${stop.code != null ? " · fermata ${stop.code}" : ""}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (skipped)
                  for (final alt in impact!.alternatives.take(2))
                    Text(
                      '→ ${alt.stop.name} · ${alt.bestKnownMeters.round()} m'
                      '${alt.sameLine ? " (stessa linea)" : ""}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            tooltip: 'Chiudi',
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

/// Senza legenda pallini e linee colorate non dicono nulla.
class _Legend extends StatelessWidget {
  const _Legend({
    required this.hasDeviation,
    required this.onlySuspendedStops,
    required this.skippedCount,
    required this.servedCount,
    required this.vehicleCount,
    required this.vehiclesSeenAt,
    required this.directions,
  });

  final bool hasDeviation;
  final bool onlySuspendedStops;
  final int skippedCount;
  final int servedCount;
  final int vehicleCount;
  final DateTime? vehiclesSeenAt;

  /// I capolinea delle direzioni disegnate, in ordine.
  final List<String> directions;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Wrap(
        spacing: 14,
        runSpacing: 4,
        children: [
          for (var i = 0; i < directions.length; i++)
            _line(
              (i == 0 ? Colors.blueGrey : Colors.teal).withValues(alpha: 0.55),
              directions.length == 1
                  ? 'percorso normale'
                  : '→ ${_shortHeadsign(directions[i])}',
              style,
            ),
          if (hasDeviation)
            _line(Colors.red.shade700, 'percorso deviato', style)
          else if (onlySuspendedStops)
            Text('nessun cambio di percorso', style: style)
          else
            Text('deviazione non ricostruita', style: style),
          _dot(
            Colors.white,
            Colors.blueGrey.shade600,
            '$servedCount fermate',
            style,
          ),
          if (skippedCount > 0)
            _dot(
              Theme.of(context).colorScheme.error,
              Colors.white,
              '$skippedCount non servite',
              style,
            ),
          if (vehicleCount > 0)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.directions_bus,
                  size: 13,
                  color: Colors.blue.shade700,
                ),
                const SizedBox(width: 4),
                Text(
                  '$vehicleCount in circolazione'
                  '${vehiclesSeenAt == null ? "" : " · ${_hhmm(vehiclesSeenAt!)}"}',
                  style: style,
                ),
              ],
            ),
          Text('tocca una fermata per il nome', style: style),
        ],
      ),
    );
  }

  static String _hhmm(DateTime t) {
    final l = t.toLocal();
    return '${l.hour.toString().padLeft(2, "0")}:'
        '${l.minute.toString().padLeft(2, "0")}';
  }

  /// Il capolinea sta in una legenda: va accorciato o la riga esplode.
  static String _shortHeadsign(String h) {
    final first = h.split(',').first.trim();
    return first.length <= 22 ? first : '${first.substring(0, 21)}…';
  }

  Widget _line(Color c, String label, TextStyle? style) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 18,
        height: 4,
        decoration: BoxDecoration(
          color: c,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
      const SizedBox(width: 6),
      Text(label, style: style),
    ],
  );

  Widget _dot(Color fill, Color border, String label, TextStyle? style) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 11,
        height: 11,
        decoration: BoxDecoration(
          color: fill,
          shape: BoxShape.circle,
          border: Border.all(color: border, width: 2),
        ),
      ),
      const SizedBox(width: 6),
      Text(label, style: style),
    ],
  );
}

/// Il pulsante "dove sono".
///
/// Sta sulla mappa e non nella scheda sotto perche' la posizione e' una
/// cosa della mappa, e perche' li' e' dove uno la cerca. Al secondo tocco
/// smette di seguirti: tenere acceso il GPS quando non serve consuma
/// batteria per niente.
class _LocateButton extends StatelessWidget {
  const _LocateButton({
    required this.active,
    required this.busy,
    required this.onPressed,
  });

  final bool active;
  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      shape: const CircleBorder(),
      elevation: 3,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: busy ? null : onPressed,
        child: SizedBox(
          width: 44,
          height: 44,
          child: busy
              ? const Padding(
                  padding: EdgeInsets.all(13),
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                )
              : Icon(
                  active ? Icons.my_location : Icons.location_searching,
                  size: 22,
                  color: active ? Colors.blue.shade700 : scheme.onSurface,
                ),
        ),
      ),
    );
  }
}
