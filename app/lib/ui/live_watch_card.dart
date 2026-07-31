import 'package:flutter/material.dart';

import '../core/deviation_service.dart';
import '../core/pipeline/vehicle_watch.dart';

/// "Guarda i mezzi adesso": osserva per qualche minuto dove sono davvero.
///
/// Serve a due cose che il testo di GTT non sa dire:
/// - la deviazione annunciata e' davvero in corso?
/// - **e' gia' finita?** GTT annuncia quasi sempre l'inizio e quasi mai la
///   fine (§10.13), e questa e' l'unica fonte che puo' accorgersene.
class LiveWatchCard extends StatefulWidget {
  const LiveWatchCard({required this.status, super.key});

  final LineStatus status;

  @override
  State<LiveWatchCard> createState() => _LiveWatchCardState();
}

class _LiveWatchCardState extends State<LiveWatchCard> {
  bool _running = false;
  int _samples = 0;
  int _vehicles = 0;
  WatchResult? _result;
  String? _error;

  Future<void> _start() async {
    setState(() {
      _running = true;
      _result = null;
      _error = null;
      _samples = 0;
      _vehicles = 0;
    });

    try {
      final result = await VehicleWatch(
        // Finestra corta: qui l'utente sta guardando lo schermo, non e' un
        // processo in sottofondo. Si ferma comunque appena ha abbastanza.
        maxDuration: const Duration(minutes: 3),
      ).watch(
        line: widget.status.line,
        shapes: widget.status.allShapes.isNotEmpty
            ? widget.status.allShapes
            : [widget.status.shape],
        onProgress: (s, v) {
          if (mounted) setState(() { _samples = s; _vehicles = v; });
        },
      );
      if (mounted) setState(() => _result = result);
    } on Object catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.my_location, size: 18),
                const SizedBox(width: 8),
                Text('Dove sono i mezzi adesso',
                    style: Theme.of(context).textTheme.titleSmall),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Guardo le posizioni reali per qualche minuto. Serve a capire '
              'se la deviazione è in corso o se è già finita — GTT la fine '
              'non la annuncia quasi mai.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            if (_running)
              _Progress(samples: _samples, vehicles: _vehicles)
            else if (_error != null)
              Text(_error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error))
            else if (_result != null)
              _Outcome(result: _result!)
            else
              FilledButton.tonalIcon(
                onPressed: _start,
                icon: const Icon(Icons.visibility_outlined),
                label: const Text('Guarda adesso'),
              ),
            if (!_running && (_result != null || _error != null))
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: _start,
                  child: const Text('Guarda di nuovo'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Progress extends StatelessWidget {
  const _Progress({required this.samples, required this.vehicles});

  final int samples;
  final int vehicles;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const LinearProgressIndicator(),
          const SizedBox(height: 8),
          Text(
            vehicles == 0
                ? 'sto guardando… ($samples ${samples == 1 ? "controllo" : "controlli"})'
                : '$vehicles ${vehicles == 1 ? "mezzo" : "mezzi"} '
                    'in vista, continuo a seguirli…',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      );
}

class _Outcome extends StatelessWidget {
  const _Outcome({required this.result});

  final WatchResult result;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (Color colour, IconData icon) = switch (result.outcome) {
      WatchOutcome.tuttiSulPercorso => (Colors.green.shade700, Icons.check_circle_outline),
      WatchOutcome.fuoriPercorso => (scheme.error, Icons.alt_route),
      WatchOutcome.nessunMezzo => (scheme.outline, Icons.bedtime_outlined),
      WatchOutcome.inconcludente => (scheme.outline, Icons.hourglass_empty),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18, color: colour),
            const SizedBox(width: 8),
            Expanded(
              child: Text(result.summary,
                  style: TextStyle(color: colour, fontWeight: FontWeight.w600)),
            ),
          ],
        ),
        // Quando i mezzi seguono il percorso normale ma GTT dichiara ancora
        // una deviazione, e' l'indizio che sia finita. Non lo si afferma:
        // lo si suggerisce, perche' due mezzi non sono una certezza.
        if (result.outcome == WatchOutcome.tuttiSulPercorso)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Se GTT dichiara ancora una deviazione, potrebbe essere già '
              'terminata senza che l\'abbiano comunicato.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            'Osservati ${result.observed.inSeconds} s, '
            '${result.samples} ${result.samples == 1 ? "controllo" : "controlli"}'
            '${result.tracks.isEmpty ? "" : ", scarto massimo ${result.maxDistance.round()} m"}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}
