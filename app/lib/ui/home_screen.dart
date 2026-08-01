import 'package:flutter/material.dart';

import '../core/deviation_service.dart';
import '../data/app_repository.dart';
import 'line_screen.dart';
import 'settings_screen.dart';

/// "Le mie linee": la schermata che rispondi guardando, prima di uscire.
class HomeScreen extends StatelessWidget {
  const HomeScreen({required this.repo, super.key});

  final AppRepository repo;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: repo,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(
            title: const Text('Le mie linee'),
            actions: [
              IconButton(
                icon: const Icon(Icons.settings_outlined),
                tooltip: 'Impostazioni',
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                      builder: (_) => SettingsScreen(repo: repo)),
                ),
              ),
            ],
          ),
          body: _body(context),
          floatingActionButton: repo.state == LoadState.ready &&
                  repo.settings.watchlist.isNotEmpty
              ? FloatingActionButton.extended(
                  onPressed: repo.isCheckingAny ? null : repo.refreshAll,
                  icon: const Icon(Icons.refresh),
                  // Da quando ogni riga ha il suo pulsante, "Controlla" da
                  // solo non dice piu' quali.
                  label: Text(repo.settings.watchlist.length == 1
                      ? 'Controlla'
                      : 'Controlla tutte'),
                )
              : null,
        );
      },
    );
  }

  Widget _body(BuildContext context) {
    // `idle` significa che il caricamento non e' ancora partito. Con una
    // watchlist da caricare va mostrato l'avanzamento: altrimenti nei
    // primi istanti la schermata resta bianca senza spiegazioni.
    if (repo.state == LoadState.loading ||
        (repo.state == LoadState.idle && repo.settings.watchlist.isNotEmpty)) {
      return _Loading(phase: repo.phase, progress: repo.progress);
    }
    if (repo.state == LoadState.error) {
      return _Message(
        icon: Icons.cloud_off,
        title: 'Qualcosa non ha funzionato',
        detail: repo.error ?? '',
        action: FilledButton(
          onPressed: repo.initialise,
          child: const Text('Riprova'),
        ),
      );
    }
    if (repo.settings.watchlist.isEmpty) {
      return _Message(
        icon: Icons.directions_bus_outlined,
        title: 'Nessuna linea',
        detail: 'Aggiungi le linee che prendi di solito.\n'
            'Il sistema lavora su quelle, non su tutta la rete.',
        action: FilledButton.icon(
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute<void>(
                builder: (_) => SettingsScreen(repo: repo)),
          ),
          icon: const Icon(Icons.add),
          label: const Text('Aggiungi una linea'),
        ),
      );
    }

    final index = repo.index;
    if (index == null) return const SizedBox.shrink();
    final lines = index.lines.values.toList()
      ..sort((a, b) => a.shortName.compareTo(b.shortName));

    return RefreshIndicator(
      onRefresh: repo.refreshAll,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 88),
        children: [
          if (!repo.settings.hasApiKey)
            _KeyBanner(
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                    builder: (_) => SettingsScreen(repo: repo)),
              ),
            ),
          if (repo.lastRefresh == null && repo.settings.hasApiKey)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text('Tocca «Controlla tutte», oppure ↻ su una linea '
                  'sola.'),
            ),
          for (final line in lines)
            _LineTile(
              shortName: line.shortName,
              longName: line.longName,
              status: repo.statusOf(line.routeId),
              checking: repo.isChecking(line.routeId),
              onCheck: () => repo.refreshLine(line),
              onTap: repo.statusOf(line.routeId) == null
                  ? null
                  : () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => LineScreen(
                            repo: repo,
                            line: line,
                          ),
                        ),
                      ),
            ),
        ],
      ),
    );
  }
}

class _LineTile extends StatelessWidget {
  const _LineTile({
    required this.shortName,
    required this.status,
    required this.checking,
    required this.onCheck,
    this.longName,
    this.onTap,
  });

  final String shortName;
  final String? longName;
  final LineStatus? status;
  final bool checking;
  final VoidCallback onCheck;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final skipped = status?.allSkippedStops.length ?? 0;

    final (Color colour, IconData icon, String label) = switch (status) {
      null => (scheme.outline, Icons.help_outline, 'non ancora controllata'),
      final s when !s.hasDeviations => (
          Colors.green.shade700,
          Icons.check_circle_outline,
          'percorso regolare'
        ),
      final s when skipped > 0 => (
          scheme.error,
          Icons.error_outline,
          '${s.reports.length} ${s.reports.length == 1 ? "avviso" : "avvisi"} · '
              '$skipped ${skipped == 1 ? "fermata non servita" : "fermate non servite"}'
        ),
      final s => (
          Colors.orange.shade800,
          Icons.warning_amber_outlined,
          '${s.reports.length} ${s.reports.length == 1 ? "avviso" : "avvisi"} · '
              'fermate tutte servite'
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
      title: Text(longName ?? 'Linea $shortName',
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Row(
        children: [
          Icon(icon, size: 16, color: colour),
          const SizedBox(width: 6),
          Expanded(
            child: Text(label,
                style: TextStyle(color: colour),
                maxLines: 2,
                overflow: TextOverflow.ellipsis),
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

class _KeyBanner extends StatelessWidget {
  const _KeyBanner({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.all(12),
      color: Theme.of(context).colorScheme.errorContainer,
      child: ListTile(
        leading: const Icon(Icons.key_outlined),
        title: const Text('Manca la chiave'),
        subtitle: const Text(
            'Senza chiave non posso leggere il testo degli avvisi.'),
        onTap: onTap,
      ),
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading({required this.phase, required this.progress});

  final String phase;
  final double progress;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            LinearProgressIndicator(
                value: progress > 0 && progress < 1 ? progress : null),
            const SizedBox(height: 20),
            Text(phase.isEmpty ? 'un momento…' : phase,
                textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(
              'La prima volta scarico gli orari di GTT: sono 24 MB.\n'
              'Poi non serve piu\' per una settimana.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.title,
    required this.detail,
    this.action,
  });

  final IconData icon;
  final String title;
  final String detail;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 56, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 16),
            Text(title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(detail,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium),
            if (action != null) ...[
              const SizedBox(height: 24),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}
