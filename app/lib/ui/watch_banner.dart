import 'dart:async';

import 'package:flutter/material.dart';

import '../data/app_repository.dart';
import 'line_screen.dart';

/// La striscia che resta in cima mentre si guardano i mezzi.
///
/// L'osservazione continua mentre si fa altro nell'app, e prima di questa
/// striscia si vedeva **solo** sulla riga di quella linea nella home:
/// dal dettaglio di un'altra linea, o dalle impostazioni, non c'era modo
/// né di sapere che era accesa né di fermarla senza tornare indietro e
/// riaprire proprio quella linea.
///
/// È lo stesso motivo per cui iOS tiene una barra in cima durante una
/// chiamata: un'attività che prosegue mentre guardi altro deve restare
/// visibile e interrompibile da dove sei.
///
/// Vive nel `builder` di `MaterialApp`, quindi sta sopra ogni schermata
/// senza che nessuna di esse ne sappia niente.
class WatchBanner extends StatefulWidget {
  const WatchBanner({required this.repo, required this.child, super.key});

  final AppRepository repo;
  final Widget child;

  @override
  State<WatchBanner> createState() => _WatchBannerState();
}

class _WatchBannerState extends State<WatchBanner> {
  Timer? _tic;

  @override
  void initState() {
    super.initState();
    // Il tempo che manca scorre anche fra un campione e l'altro: senza
    // questo resterebbe fermo fino al prossimo aggiornamento, cioe' fino
    // a 20 secondi, e sembrerebbe bloccato.
    _tic = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted && widget.repo.watchingRouteId != null) setState(() {});
    });
  }

  @override
  void dispose() {
    _tic?.cancel();
    super.dispose();
  }

  /// Porta alla linea osservata da qualunque punto dell'app.
  ///
  /// Si torna prima alla radice: altrimenti toccando la striscia mentre si
  /// e' gia' su quella linea se ne impilerebbe una seconda copia.
  void _apri() {
    final line = widget.repo.watchingLine;
    if (line == null) return;
    final nav = Navigator.of(context);
    nav.popUntil((r) => r.isFirst);
    nav.push(MaterialPageRoute<void>(
      builder: (_) => LineScreen(repo: widget.repo, line: line),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.repo,
      builder: (context, _) {
        final repo = widget.repo;
        final line = repo.watchingLine;
        // Sulla schermata della linea osservata la striscia e' di troppo:
        // la scheda sotto dice le stesse cose e ha il suo pulsante.
        if (line == null || repo.visibleLineRouteId == line.routeId) {
          return widget.child;
        }

        return Column(
          children: [
            _Striscia(
              linea: line.shortName,
              mezzi: repo.liveTracks.length,
              tempo: _tempo(repo),
              onTap: _apri,
              onStop: repo.stopWatch,
            ),
            // La striscia ha gia' consumato la barra di stato: senza
            // toglierla, ogni AppBar sotto la conta una seconda volta e
            // lascia un vuoto di una sessantina di punti.
            Expanded(
              child: MediaQuery.removePadding(
                context: context,
                removeTop: true,
                child: widget.child,
              ),
            ),
          ],
        );
      },
    );
  }

  /// "ancora 3 min" mentre c'e' una fine, "da 4 min" quando non c'e'.
  static String _tempo(AppRepository repo) {
    if (repo.watchIsContinuous) {
      final d = repo.watchElapsed ?? Duration.zero;
      return d.inMinutes < 1 ? 'in continuo' : 'da ${d.inMinutes} min';
    }
    final resta = repo.watchRemaining ?? Duration.zero;
    if (resta.inSeconds <= 0) return 'sto finendo';
    if (resta.inSeconds < 60) return 'ancora ${resta.inSeconds} s';
    // Si arrotonda per ECCESSO al minuto: "ancora 1 min" quando ne
    // restano 70 secondi sarebbe una bugia breve ma fastidiosa. E si usa
    // ceil() e non inMinutes+1, che con 5 minuti esatti direbbe 6.
    return 'ancora ${(resta.inSeconds / 60).ceil()} min';
  }
}

class _Striscia extends StatelessWidget {
  const _Striscia({
    required this.linea,
    required this.mezzi,
    required this.tempo,
    required this.onTap,
    required this.onStop,
  });

  final String linea;
  final int mezzi;
  final String tempo;
  final VoidCallback onTap;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final blu = Colors.blue.shade700;
    return Material(
      color: Colors.blue.shade50,
      child: SafeArea(
        bottom: false,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 4, 6),
            child: Row(
              children: [
                Icon(Icons.directions_bus, size: 18, color: blu),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    // Numero della linea, quanti mezzi, quanto manca: le
                    // tre cose che uno vuole sapere senza aprire niente.
                    '$linea · ${mezzi == 0 ? "cerco i mezzi" : "$mezzi ${mezzi == 1 ? "mezzo" : "mezzi"}"} · $tempo',
                    style: TextStyle(color: blu, fontWeight: FontWeight.w600),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                // Semantics e non Tooltip: la striscia vive nel `builder`
                // di MaterialApp, quindi STA SOPRA il Navigator — e con
                // lui sopra l'Overlay che i tooltip pretendono. Con
                // `tooltip:` l'app si apriva sulla schermata rossa.
                Semantics(
                  button: true,
                  label: 'Interrompi l\'osservazione',
                  child: IconButton(
                    // La stessa icona del pulsante nella schermata della
                    // linea: e' lo stesso gesto, e due simboli diversi
                    // per la stessa azione si imparano due volte.
                    icon: const Icon(Icons.stop_outlined),
                    color: blu,
                    onPressed: onStop,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
