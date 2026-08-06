import 'package:flutter/material.dart';

import '../core/deviation_service.dart';

/// Una riga di "Le mie linee": stato in una frase, e i comandi.
///
/// Sta in un file suo perche' e' l'unico pezzo di interfaccia con uno
/// stato transitorio importante — l'avanzamento del controllo — e quello
/// si verifica con un test, non guardandolo: dura pochi secondi.
class LineTile extends StatelessWidget {
  const LineTile({
    required this.shortName,
    required this.status,
    required this.checking,
    required this.phase,
    required this.watching,
    required this.watchedVehicles,
    required this.checkedAt,
    required this.onCheck,
    this.onTap,
    super.key,
  });

  final String shortName;
  final LineStatus? status;
  final bool checking;

  /// A che punto e' il controllo, mentre e' in corso.
  final String? phase;

  /// Si stanno guardando i mezzi di questa linea, adesso.
  ///
  /// L'osservazione continua anche uscendo dalla schermata della linea:
  /// se qui non si vedesse, uno non saprebbe che e' ancora accesa e la
  /// lascerebbe girare interrogando GTT per niente.
  final bool watching;
  final int watchedVehicles;

  /// Quando e' stato fatto il controllo che si sta mostrando.
  ///
  /// Se non e' di oggi va detto: gli esiti sopravvivono alla chiusura
  /// dell'app, e "2 fermate non servite" senza data sembra adesso.
  final DateTime? checkedAt;
  final VoidCallback onCheck;
  final VoidCallback? onTap;

  /// "ieri" o "il 30/7" quando l'esito non e' di oggi. null se lo e'.
  String? get _vecchio {
    final t = checkedAt;
    if (t == null) return null;
    final oggi = DateTime.now();
    final giorni = DateTime(
      oggi.year,
      oggi.month,
      oggi.day,
    ).difference(DateTime(t.year, t.month, t.day)).inDays;
    return switch (giorni) {
      0 => null,
      1 => 'ieri',
      _ => 'il ${t.day}/${t.month}',
    };
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final skipped = status?.allSkippedStops.length ?? 0;
    // Gli avvisi che devono ancora cominciare non entrano nel riassunto
    // di adesso: si dicono a parte, sotto.
    // Per AVVISO, non per rapporto: un avviso che riguarda tutte e due le
    // direzioni viene analizzato due volte, e contarlo due volte diceva
    // "6 avvisi" dove GTT ne ha pubblicati 3.
    final attivi = status?.activeReports
            .map((r) => r.notice.id)
            .toSet()
            .length ??
        0;
    final futuri = status?.scheduledReports
            .map((r) => r.notice.id)
            .toSet()
            .length ??
        0;

    String avvisi(int n) => '$n ${n == 1 ? "avviso" : "avvisi"}';

    // Il titolo e' LA RISPOSTA, corta e sempre su una riga: e' quello che
    // uno cerca guardando l'elenco. Il conteggio degli avvisi non e' una
    // risposta — sapere che ce ne sono tre non dice se il bus passa — e
    // messo in cima mandava il titolo a capo. Sta sotto, coi dettagli.
    final (Color colour, IconData icon, String label) = switch (status) {
      // Mai vuota: una riga senza titolo sembra un errore di caricamento.
      null => (scheme.outline, Icons.help_outline, 'Da controllare'),
      final s when attivi == 0 && futuri > 0 => (
        Colors.blue.shade700,
        Icons.event_outlined,
        'Nulla in corso',
      ),
      final s when !s.hasDeviations => (
        Colors.green.shade700,
        Icons.check_circle_outline,
        'Percorso regolare',
      ),
      final s when skipped > 0 => (
        scheme.error,
        Icons.error_outline,
        skipped == 1 ? '1 fermata non servita' : '$skipped fermate non servite',
      ),
      final s => (
        Colors.orange.shade800,
        Icons.warning_amber_outlined,
        'Fermate tutte servite',
      ),
    };

    // I dettagli: quanti avvisi, quanti in programma, di quando e'
    // l'esito. Piccoli e grigi, perche' si leggono solo se il titolo ti
    // ha gia' interessato.
    final dettagli = <String>[
      if (attivi > 0) avvisi(attivi),
      if (futuri > 0) '${avvisi(futuri)} in programma',
      if (_vecchio != null) 'controllata ${_vecchio!}',
    ].join(' · ');

    return ListTile(
      onTap: onTap,
      leading: Container(
        width: 52,
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: scheme.primaryContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          shortName,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: scheme.onPrimaryContainer,
          ),
        ),
      ),
      // Il titolo e' lo STATO, non i capolinea. I due capolinea non ci
      // stanno su una riga — si troncavano a meta' — e chi ha aggiunto
      // la linea sa gia' dove va: quello che non sa e' se oggi devia.
      title: watching
          ? Row(
              children: [
                Icon(
                  Icons.directions_bus,
                  size: 16,
                  color: Colors.blue.shade700,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    watchedVehicles == 0
                        ? 'osservazione in corso…'
                        : '$watchedVehicles ${watchedVehicles == 1 ? "mezzo" : "mezzi"} '
                              'in osservazione',
                    style: TextStyle(color: Colors.blue.shade700),
                  ),
                ),
              ],
            )
          : checking
          ? Text(
              phase ?? 'controllo in corso…',
              style: TextStyle(color: scheme.primary),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            )
          : Row(
              children: [
                Icon(icon, size: 17, color: colour),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      color: colour,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
      subtitle: checking
          // Mentre controlla, la barra: una riga muta con la rotella
          // accanto sembra un blocco.
          ? Padding(
              padding: const EdgeInsets.only(top: 6),
              child: LinearProgressIndicator(
                minHeight: 3,
                borderRadius: BorderRadius.circular(2),
              ),
            )
          : dettagli.isEmpty
          ? null
          : Text(
              dettagli,
              style: TextStyle(color: scheme.outline, fontSize: 12.5),
              // Qui si puo' andare a capo: e' piccolo e grigio, e una
              // seconda riga si legge senza fatica. Troncare con i
              // puntini nascondeva quando era stato fatto il controllo.
              // Il TITOLO invece resta su una riga, sempre.
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Controllare una linea sola: e' la cosa che si fa piu' spesso,
          // ed e' quella che consuma meno richieste.
          if (checking)
            const SizedBox(
              width: 40,
              height: 40,
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
              tooltip: 'Controlla solo la $shortName',
              onPressed: onCheck,
            ),
          if (onTap != null) const Icon(Icons.chevron_right),
        ],
      ),
    );
  }
}
