import 'package:flutter/material.dart';

import '../core/deviation_service.dart';
import '../core/models/notice.dart';
import '../core/models/transit.dart';
import '../data/app_repository.dart';
import '../core/pipeline/stop_impact.dart';
import 'line_map.dart';
import 'live_watch_card.dart';

/// Il dettaglio di una linea: cosa succede, dove, e cosa fare.
///
/// L'ordine conta. Prima le fermate che saltano, che e' la risposta alla
/// domanda vera; poi la mappa, che serve a confermare; e in fondo sempre
/// il testo originale di GTT, cosi' se il sistema sbaglia il dato grezzo
/// resta a disposizione (§6.2).
class LineScreen extends StatefulWidget {
  const LineScreen({required this.repo, required this.line, super.key});

  final AppRepository repo;
  final TransitLine line;

  @override
  State<LineScreen> createState() => _LineScreenState();
}

class _LineScreenState extends State<LineScreen> {
  // L'osservazione NON sta qui: sta nel repository, perche' deve
  // continuare anche quando questa schermata viene chiusa. Qui resta solo
  // la scelta della durata, che e' una preferenza di chi guarda.
  WatchWindow _window = WatchWindow.media;

  @override
  void initState() {
    super.initState();
    // Dopo il frame: cambiarlo durante la costruzione farebbe partire un
    // notifyListeners mentre l'albero si sta ancora montando.
    WidgetsBinding.instance.addPostFrameCallback(
        (_) => widget.repo.setVisibleLine(widget.line.routeId));
  }

  @override
  void dispose() {
    if (widget.repo.visibleLineRouteId == widget.line.routeId) {
      widget.repo.visibleLineRouteId = null;
      // Niente notifyListeners qui: si sta smontando, e chi resta viene
      // ricostruito comunque dal Navigator.
    }
    super.dispose();
  }

  void _startWatch() =>
      widget.repo.startWatch(widget.line, _window.duration);

  String get _checkedLabel {
    final t = widget.repo.checkedAt(widget.line.routeId);
    if (t == null) return '';
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return '  ·  controllata alle $h:$m';
  }

  @override
  Widget build(BuildContext context) {
    // Si ascolta il repository perche' il controllo della singola linea
    // avviene da qui: il risultato deve comparire senza tornare indietro.
    return ListenableBuilder(
      listenable: widget.repo,
      builder: (context, _) => _content(context),
    );
  }

  Widget _content(BuildContext context) {
    final status = widget.repo.statusOf(widget.line.routeId);
    // La schermata si apre solo su una linea gia' controllata, ma toglierla
    // dalla watchlist mentre e' aperta la lascerebbe senza dati.
    if (status == null) return const Scaffold(body: SizedBox.shrink());
    final checking = widget.repo.isChecking(widget.line.routeId);
    final osservando = widget.repo.isWatching(widget.line.routeId);
    final esito = widget.repo.watchResultOf(widget.line.routeId);
    // Se si sta guardando un'ALTRA linea, va detto: partire da qui la
    // fermerebbe, e non e' una cosa che deve succedere di sorpresa.
    final altraInCorso = widget.repo.watchingRouteId != null && !osservando
        ? widget.repo.watchingLineName
        : null;

    return Scaffold(
      appBar: AppBar(
        title: Text('Linea ${status.line.shortName}'),
        actions: [
          if (checking)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 18),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Ricontrolla la ${status.line.shortName}',
              onPressed: () => widget.repo.refreshLine(widget.line),
            ),
        ],
        bottom: checking
            ? PreferredSize(
                preferredSize: const Size.fromHeight(40),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      LinearProgressIndicator(
                        minHeight: 3,
                        borderRadius: BorderRadius.circular(2),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        widget.repo.phaseOfLine(widget.line.routeId) ??
                            'controllo…',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.primary),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              )
            : PreferredSize(
          preferredSize: const Size.fromHeight(20),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8, left: 16, right: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                // Con il controllo per singola linea le righe non sono
                // piu' tutte dello stesso momento: l'ora va detta qui,
                // dove si guardano i risultati.
                '${status.shape.headsign}$_checkedLabel',
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
          LineMap(
            status: status,
            vehicles: osservando ? widget.repo.liveTracks : const [],
            observed: esito?.consensus,
          ),
          LiveWatchCard(
            running: osservando,
            samples: widget.repo.watchSamples,
            liveTracks: osservando ? widget.repo.liveTracks : const [],
            result: esito,
            error: widget.repo.watchError,
            window: _window,
            shape: status.shape,
            altraLinea: altraInCorso,
            onStart: _startWatch,
            onStop: widget.repo.stopWatch,
            onWindowChanged: (w) => setState(() => _window = w),
          ),
          if (status.reports.isEmpty)
            const Padding(
              padding: EdgeInsets.all(32),
              child: _AllGood(),
            )
          else ...[
            if (status.activeReports.isEmpty)
              const Padding(
                padding: EdgeInsets.all(32),
                child: _AllGood(nienteOra: true),
              ),
            for (final report in status.activeReports)
              _ReportCard(report: report, status: status),
            // In fondo, dopo cio' che succede adesso: sapere del 24 agosto
            // e' utile, ma non e' la risposta alla domanda di oggi.
            if (status.scheduledReports.isNotEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 28, 16, 4),
                child: Text('Piu\' avanti',
                    style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            for (final report in status.scheduledReports)
              _ReportCard(
                  report: report, status: status, daAvvenire: true),
          ],
        ],
      ),
    );
  }
}

class _AllGood extends StatelessWidget {
  const _AllGood({this.nienteOra = false});

  /// C'e' qualcosa in programma, ma non adesso: dirlo "nessun avviso"
  /// sarebbe falso.
  final bool nienteOra;

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle_outline,
                size: 56, color: Colors.green.shade700),
            const SizedBox(height: 16),
            Text(nienteOra
                ? 'Adesso il percorso e\' regolare'
                : 'Nessun avviso attivo su questa linea'),
          ],
        ),
      );
}

class _ReportCard extends StatelessWidget {
  const _ReportCard({
    required this.report,
    required this.status,
    this.daAvvenire = false,
  });

  final DeviationReport report;
  final LineStatus status;

  /// La variazione deve ancora cominciare.
  final bool daAvvenire;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (daAvvenire)
            _ScheduledStrip(notice: report.notice, now: status.checkedAt)
          else
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

/// "Comincia fra 23 giorni": la data da sola fa fare il conto a mano.
class _ScheduledStrip extends StatelessWidget {
  const _ScheduledStrip({required this.notice, required this.now});

  final RawNotice notice;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final giorni = notice.daysUntilStart(now) ?? 0;
    final quando = switch (giorni) {
      1 => 'da domani',
      2 => 'da dopodomani',
      _ => 'fra $giorni giorni',
    };
    final d = notice.validFrom!;
    final data = '${d.day.toString().padLeft(2, '0')}/'
        '${d.month.toString().padLeft(2, '0')}/${d.year}';
    final blu = Colors.blue.shade700;

    return Container(
      width: double.infinity,
      color: blu.withValues(alpha: 0.12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(Icons.event_outlined, size: 18, color: blu),
          const SizedBox(width: 8),
          Expanded(
            child: Text('Non ancora in vigore — comincia $quando ($data)',
                style: TextStyle(color: blu, fontWeight: FontWeight.w600)),
          ),
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
          // Quando GTT pubblica la stessa variazione in due posti se ne
          // mostra una sola, ed e' giusto dire perche': chi confronta con
          // il sito deve capire da dove vengono le date.
          if (n.isMerged)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'GTT lo pubblica sia negli avvisi sia nella tabella delle '
                'variazioni. Qui c\'è il testo più completo dei due, con le '
                'date della tabella.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
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
