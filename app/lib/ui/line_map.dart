import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../core/deviation_service.dart';
import '../core/geo/projection.dart' as geo;
import '../core/pipeline/stop_impact.dart';

/// La mappa della linea: percorso normale e, sopra, le deviazioni.
///
/// Si mostra SEMPRE, anche quando nessuna deviazione e' stata ricostruita.
/// Vedere dove passa la linea e' utile comunque, e nasconderla proprio
/// quando il testo non si e' capito lascia l'utente senza nulla in mano
/// nel momento peggiore.
///
/// Convenzioni grafiche dalla specifica §6.2: percorso normale sottile e
/// grigio, tratto deviato rosso e spesso, fermate saltate cerchiate.
class LineMap extends StatelessWidget {
  const LineMap({required this.status, super.key, this.height = 260});

  final LineStatus status;
  final double height;

  @override
  Widget build(BuildContext context) {
    final official = status.shape.points
        .map((p) => LatLng(p.lat, p.lon))
        .toList(growable: false);
    if (official.length < 2) return const SizedBox.shrink();

    final deviations = status.reports
        .where((r) => r.hasMap)
        .map((r) => r.deviatedGeometry!
            .map((p) => LatLng(p.lat, p.lon))
            .toList(growable: false))
        .toList();

    final skipped = status.allSkippedStops;

    // Si inquadra la deviazione se c'e', altrimenti tutta la linea.
    final bounds = LatLngBounds.fromPoints(
        deviations.isNotEmpty ? deviations.expand((d) => d).toList() : official);

    return Column(
      children: [
        SizedBox(
          height: height,
          child: FlutterMap(
            options: MapOptions(
              initialCameraFit: CameraFit.bounds(
                bounds: bounds,
                padding: const EdgeInsets.all(28),
              ),
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.pinchZoom |
                    InteractiveFlag.drag |
                    InteractiveFlag.doubleTapZoom,
              ),
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'dev.tcdesign.gtt_deviazioni',
              ),
              PolylineLayer(
                polylines: [
                  Polyline(
                    points: official,
                    strokeWidth: 4,
                    color: Colors.blueGrey.withValues(alpha: 0.55),
                  ),
                  for (final d in deviations)
                    Polyline(
                      points: d,
                      strokeWidth: 6,
                      color: Colors.red.shade700,
                    ),
                ],
              ),
              MarkerLayer(
                markers: [
                  for (final s in skipped)
                    Marker(
                      point: LatLng(s.stop.position.lat, s.stop.position.lon),
                      width: 18,
                      height: 18,
                      child: _SkippedDot(
                          declared: s.status == StopStatus.declaredSuspended),
                    ),
                  _endMarker(official.first, Colors.green.shade700),
                  _endMarker(official.last, Colors.blueGrey.shade700),
                ],
              ),
              const RichAttributionWidget(
                alignment: AttributionAlignment.bottomLeft,
                attributions: [TextSourceAttribution('OpenStreetMap')],
              ),
            ],
          ),
        ),
        _Legend(
          hasDeviation: deviations.isNotEmpty,
          skippedCount: skipped.length,
        ),
      ],
    );
  }

  static Marker _endMarker(LatLng at, Color colour) => Marker(
        point: at,
        width: 12,
        height: 12,
        child: Container(
          decoration: BoxDecoration(
            color: colour,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2),
          ),
        ),
      );

  static LatLng centreOf(List<geo.GeoPoint> pts) {
    var lat = 0.0, lon = 0.0;
    for (final p in pts) {
      lat += p.lat;
      lon += p.lon;
    }
    return LatLng(lat / pts.length, lon / pts.length);
  }
}

class _SkippedDot extends StatelessWidget {
  const _SkippedDot({required this.declared});

  final bool declared;

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.error,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2),
        ),
        child: const Icon(Icons.close, size: 10, color: Colors.white),
      );
}

/// Senza legenda due linee colorate non dicono nulla.
class _Legend extends StatelessWidget {
  const _Legend({required this.hasDeviation, required this.skippedCount});

  final bool hasDeviation;
  final int skippedCount;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Wrap(
        spacing: 16,
        runSpacing: 4,
        children: [
          _item(Colors.blueGrey.withValues(alpha: 0.55), 'percorso normale',
              style),
          if (hasDeviation)
            _item(Colors.red.shade700, 'percorso deviato', style)
          else
            Text('deviazione non ricostruita', style: style),
          if (skippedCount > 0)
            _item(Theme.of(context).colorScheme.error,
                '$skippedCount non servite', style, circle: true),
        ],
      ),
    );
  }

  Widget _item(Color c, String label, TextStyle? style,
          {bool circle = false}) =>
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: circle ? 10 : 18,
            height: circle ? 10 : 4,
            decoration: BoxDecoration(
              color: c,
              shape: circle ? BoxShape.circle : BoxShape.rectangle,
              borderRadius: circle ? null : BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 6),
          Text(label, style: style),
        ],
      );
}
