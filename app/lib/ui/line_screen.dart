import 'package:flutter/material.dart';

import '../core/deviation_service.dart';
import '../core/pipeline/stop_impact.dart';
import 'line_map.dart';

/// Il dettaglio di una linea: cosa succede, dove, e cosa fare.
///
/// L'ordine conta. Prima le fermate che saltano, che e' la risposta alla
/// domanda vera; poi la mappa, che serve a confermare; e in fondo sempre
/// il testo originale di GTT, cosi' se il sistema sbaglia il dato grezzo
/// resta a disposizione (§6.2).
class LineScreen extends StatelessWidget {
  const LineScreen({required this.status, super.key});

  final LineStatus status;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Linea ${status.line.shortName}'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(20),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8, left: 16, right: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                status.shape.headsign,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
        ),
      ),
      body: ListView(
        children: [
          // La mappa sta in cima e c'e' SEMPRE: vedere dove passa la linea
          // serve anche quando la deviazione non si e' potuta ricostruire.
          LineMap(status: status),
          if (status.reports.isEmpty)
            const Padding(
              padding: EdgeInsets.all(32),
              child: _AllGood(),
            )
          else
            for (final report in status.reports)
              _ReportCard(report: report, status: status),
        ],
      ),
    );
  }
}

class _AllGood extends StatelessWidget {
  const _AllGood();

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle_outline,
                size: 56, color: Colors.green.shade700),
            const SizedBox(height: 16),
            const Text('Nessun avviso attivo su questa linea'),
          ],
        ),
      );
}

class _ReportCard extends StatelessWidget {
  const _ReportCard({required this.report, required this.status});

  final DeviationReport report;
  final LineStatus status;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ConfidenceStrip(report: report),

          // 1. La risposta alla domanda vera.
          if (report.skippedStops.isNotEmpty)
            _SkippedStops(stops: report.skippedStops)
          else if (report.impact != null)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Text('Il mezzo devia ma serve comunque tutte le '
                  'fermate del tratto.'),
            ),


          // 3. Il testo di GTT, sempre.
          _OriginalText(report: report),
        ],
      ),
    );
  }
}

class _ConfidenceStrip extends StatelessWidget {
  const _ConfidenceStrip({required this.report});

  final DeviationReport report;

  @override
  Widget build(BuildContext context) {
    final (Color bg, IconData icon, String label) = switch (report.confidence) {
      Confidence.confermata => (
          Colors.green.shade700,
          Icons.verified_outlined,
          'Ricostruita e verificata'
        ),
      Confidence.probabile => (
          Colors.orange.shade800,
          Icons.help_outline,
          'Probabile — da confermare'
        ),
      Confidence.soloTesto => (
          Theme.of(context).colorScheme.outline,
          Icons.article_outlined,
          'Solo il testo di GTT'
        ),
    };

    return Container(
      width: double.infinity,
      color: bg.withValues(alpha: 0.12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: bg),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: TextStyle(
                        color: bg, fontWeight: FontWeight.w600, fontSize: 13)),
                if (report.whyIncomplete != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(report.whyIncomplete!,
                        style: Theme.of(context).textTheme.bodySmall),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SkippedStops extends StatelessWidget {
  const _SkippedStops({required this.stops});

  final List<StopImpact> stops;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            stops.length == 1
                ? 'Una fermata non è servita'
                : '${stops.length} fermate non sono servite',
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(color: scheme.error),
          ),
          const SizedBox(height: 8),
          for (final s in stops) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.do_not_disturb_on_outlined,
                    size: 18, color: scheme.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(s.stop.name,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      if (s.status == StopStatus.declaredSuspended)
                        Text('sospesa da GTT',
                            style: Theme.of(context).textTheme.bodySmall),
                      for (final alt in s.alternatives)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Row(
                            children: [
                              const Icon(Icons.directions_walk, size: 15),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  '${alt.stop.name} · '
                                  '${alt.bestKnownMeters.round()} m'
                                  '${alt.walkingMeters == null ? " in linea d'aria" : " a piedi"}'
                                  '${alt.sameLine ? " · stessa linea" : ""}',
                                  style:
                                      Theme.of(context).textTheme.bodySmall,
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (s.alternatives.isEmpty)
                        Text('nessuna alternativa entro 400 m',
                            style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
          ],
        ],
      ),
    );
  }
}

class _OriginalText extends StatelessWidget {
  const _OriginalText({required this.report});

  final DeviationReport report;

  @override
  Widget build(BuildContext context) {
    final n = report.notice;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Testo di GTT',
              style: Theme.of(context)
                  .textTheme
                  .labelMedium
                  ?.copyWith(color: Theme.of(context).colorScheme.primary)),
          const SizedBox(height: 4),
          if (n.headline != null && n.headline!.isNotEmpty)
            Text(n.headline!,
                style: const TextStyle(fontWeight: FontWeight.w600)),
          Text(n.text),
          if (n.reason != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('Motivo: ${n.reason}',
                  style: Theme.of(context).textTheme.bodySmall),
            ),
          if (n.validUntil != null)
            Text('Fino al ${_date(n.validUntil!)}',
                style: Theme.of(context).textTheme.bodySmall)
          else
            Text('Senza data di fine prevista',
                style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }

  static String _date(DateTime d) =>
      '${d.day.toString().padLeft(2, "0")}/'
      '${d.month.toString().padLeft(2, "0")}/${d.year}';
}
