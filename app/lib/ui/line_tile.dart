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

    final (Color colour, IconData icon, String label) = switch (status) {
      null => (scheme.outline, Icons.help_outline, 'non ancora controllata'),
      final s when attivi == 0 && futuri > 0 => (
        Colors.blue.shade700,
        Icons.event_outlined,
        'in corso nulla · ${avvisi(futuri)} in programma',
      ),
      final s when !s.hasDeviations => (
        Colors.green.shade700,
        Icons.check_circle_outline,
        'percorso regolare',
      ),
      final s when skipped > 0 => (
        scheme.error,
        Icons.error_outline,
        '${avvisi(attivi)} · $skipped '
            '${skipped == 1 ? "fermata non servita" : "fermate non servite"}',
      ),
      final s => (
        Colors.orange.shade800,
        Icons.warning_amber_outlined,
        '${avvisi(attivi)} · fermate tutte servite',
      ),
    };

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
                        ? 'sto guardando i mezzi…'
                        : 'sto guardando $watchedVehicles '
                              '${watchedVehicles == 1 ? "mezzo" : "mezzi"}',
                    style: TextStyle(color: Colors.blue.shade700),
                  ),
                ),
              ],
            )
          : checking
          ? Text(
              phase ?? 'controllo…',
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
                    futuri > 0 && attivi > 0
                        ? '$label · +$futuri in programma'
                        : label,
                    style: TextStyle(color: colour),
                    maxLines: 2,
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
          // Un esito di ieri non si spaccia per fresco: la data si dice
          // solo quando NON e' di oggi, o sarebbe rumore su ogni riga.
          : _vecchio == null
          ? null
          : Text(
              'controllata ${_vecchio!}',
              style: TextStyle(color: scheme.outline, fontSize: 12.5),
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
