import 'package:flutter/material.dart';

import '../core/pipeline/vehicle_watch.dart';

/// Per quanto guardare.
///
/// La durata scelta e' **vincolante**: si guarda per tutto il tempo, non
/// finche' basta. Prima non era cosi' e il selettore non serviva a nulla —
/// su una linea in servizio due campioni bastavano, cioe' 31 secondi, sia
/// che si fossero chiesti 1 o 10 minuti.
enum WatchWindow {
  breve(Duration(minutes: 1), '1 min'),
  media(Duration(minutes: 3), '3 min'),
  lunga(Duration(minutes: 5), '5 min'),
  moltoLunga(Duration(minutes: 10), '10 min'),

  /// Finche' non si dice basta. Per guardare i mezzi muoversi sulla mappa,
  /// che e' una cosa diversa dal rispondere a una domanda.
  continua(Duration(hours: 2), 'in continuo');

  const WatchWindow(this.duration, this.label);

  final Duration duration;
  final String label;

  bool get isContinuous => this == WatchWindow.continua;
}

/// "Dove sono i mezzi adesso": comandi ed esito.
///
/// Non tiene lo stato dell'osservazione: quello sta nella schermata, che
/// deve passarlo anche alla mappa per disegnarci sopra i mezzi. Qui c'e'
/// solo la presentazione.
class LiveWatchCard extends StatelessWidget {
  const LiveWatchCard({
    required this.running,
    required this.samples,
    required this.liveTracks,
    required this.result,
    required this.window,
    required this.onStart,
    required this.onStop,
    required this.onWindowChanged,
    super.key,
    this.error,
  });

  final bool running;
  final int samples;
  final List<VehicleTrack> liveTracks;
  final WatchResult? result;
  final String? error;
  final WatchWindow window;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final ValueChanged<WatchWindow> onWindowChanged;

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
              'Guardo le posizioni reali e le disegno sulla mappa. Serve a '
              'capire se la deviazione è in corso o se è già finita — GTT '
              'la fine non la annuncia quasi mai.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),

            // La durata si sceglie prima, e resta visibile: sapere per
            // quanto si sta guardando fa capire quanto aspettare.
            Text('Per quanto guardare',
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final w in WatchWindow.values)
                  ChoiceChip(
                    label: Text(w.label),
                    selected: window == w,
                    onSelected: running ? null : (_) => onWindowChanged(w),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
            const SizedBox(height: 12),

            if (running) ...[
              _Progress(samples: samples, tracks: liveTracks),
              const SizedBox(height: 10),
              // Si puo' sempre smettere: in continuo e' l'unico modo, e
              // sugli altri e' scortese obbligare ad aspettare.
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: onStop,
                  icon: const Icon(Icons.stop_outlined, size: 18),
                  label: Text(window.isContinuous ? 'Basta così' : 'Ferma'),
                ),
              ),
            ]
            else if (error != null)
              Text(error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error))
            else if (result != null)
              _Outcome(result: result!)
            else
              FilledButton.tonalIcon(
                onPressed: onStart,
                icon: const Icon(Icons.visibility_outlined),
                label: Text(window.isContinuous
                    ? 'Segui i mezzi'
                    : 'Guarda adesso'),
              ),

            if (!running && (result != null || error != null))
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: onStart,
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
  const _Progress({required this.samples, required this.tracks});

  final int samples;
  final List<VehicleTrack> tracks;

  @override
  Widget build(BuildContext context) {
    final off = tracks.where((t) => t.isOffRoute).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const LinearProgressIndicator(),
        const SizedBox(height: 8),
        Text(
          tracks.isEmpty
              ? 'sto guardando… ($samples ${samples == 1 ? "controllo" : "controlli"})'
              : '${tracks.length} ${tracks.length == 1 ? "mezzo" : "mezzi"} '
                  'sulla mappa'
                  '${off > 0 ? ", di cui $off fuori percorso" : ""}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

/// "9 min 40 s" invece di "580 s": da quando si puo' guardare per dieci
/// minuti, i secondi da soli non si leggono piu'.
String _durata(Duration d) {
  if (d.inSeconds < 90) return '${d.inSeconds} s';
  final m = d.inMinutes;
  final s = d.inSeconds - m * 60;
  return s == 0 ? '$m min' : '$m min $s s';
}

class _Outcome extends StatelessWidget {
  const _Outcome({required this.result});

  final WatchResult result;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (Color colour, IconData icon) = switch (result.outcome) {
      WatchOutcome.tuttiSulPercorso => (
          Colors.green.shade700,
          Icons.check_circle_outline
        ),
      WatchOutcome.fuoriPercorso => (scheme.error, Icons.alt_route),
      WatchOutcome.nessunMezzo => (scheme.outline, Icons.bedtime_outlined),
      WatchOutcome.feedSpento => (scheme.outline, Icons.cloud_off_outlined),
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
                  style:
                      TextStyle(color: colour, fontWeight: FontWeight.w600)),
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
        // Un mezzo solo, visto due volte, non e' una prova: puo' essere
        // fermo al capolinea. Non cambia l'esito, ma va detto.
        if (!result.enoughVehicles && result.tracks.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              result.vehiclesSeen == 1
                  ? 'Su un mezzo solo: prendilo con le pinze.'
                  : 'Pochi mezzi seguiti abbastanza a lungo: '
                      'prendilo con le pinze.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            'Osservati ${_durata(result.observed)}, '
            '${result.samples} ${result.samples == 1 ? "controllo" : "controlli"}'
            '${result.tracks.isEmpty ? "" : ", scarto massimo ${result.maxDistance.round()} m"}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}
