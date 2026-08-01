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
    required this.onCheck,
    this.longName,
    this.onTap,
    super.key,
  });

  final String shortName;
  final String? longName;
  final LineStatus? status;
  final bool checking;

  /// A che punto e' il controllo, mentre e' in corso.
  final String? phase;
  final VoidCallback onCheck;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final skipped = status?.allSkippedStops.length ?? 0;
    // Gli avvisi che devono ancora cominciare non entrano nel riassunto
    // di adesso: si dicono a parte, sotto.
    final attivi = status?.activeReports.length ?? 0;
    final futuri = status?.scheduledReports.length ?? 0;

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
      title: Text(
        longName ?? 'Linea $shortName',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: checking
          // Durante il controllo il posto del riassunto lo prende
          // l'avanzamento: quello vecchio non e' piu' vero, e una riga
          // muta con la rotella accanto sembra un blocco.
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 4),
                LinearProgressIndicator(
                  minHeight: 3,
                  borderRadius: BorderRadius.circular(2),
                ),
                const SizedBox(height: 5),
                Text(
                  phase ?? 'controllo…',
                  style: TextStyle(color: scheme.primary, fontSize: 12.5),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            )
          : Row(
              children: [
                Icon(icon, size: 16, color: colour),
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
