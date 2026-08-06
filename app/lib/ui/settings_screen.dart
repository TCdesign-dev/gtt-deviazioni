import 'package:flutter/material.dart';

import '../data/app_repository.dart';
import '../data/settings.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({required this.repo, super.key});

  final AppRepository repo;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _lineController = TextEditingController();
  final _keyController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _keyController.text = widget.repo.settings.apiKey ?? '';
  }

  @override
  void dispose() {
    _lineController.dispose();
    _keyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final repo = widget.repo;
    return Scaffold(
      appBar: AppBar(title: const Text('Impostazioni')),
      body: ListenableBuilder(
        listenable: repo,
        builder: (context, _) => ListView(
          children: [
            const _SectionTitle('Le tue linee'),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                'Poche linee, quelle che prendi davvero: il controllo '
                'avviene per singola linea.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _lineController,
                      textCapitalization: TextCapitalization.characters,
                      decoration: const InputDecoration(
                        labelText: 'Numero o nome',
                        hintText: '55, 4, STAR 1, 58/',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      onSubmitted: (_) => _addLine(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _addLine,
                    child: const Text('Aggiungi'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            for (final line in repo.settings.watchlist)
              ListTile(
                dense: true,
                leading: const Icon(Icons.directions_bus_outlined),
                title: Text(line),
                trailing: IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'Togli',
                  onPressed: () => repo.removeLine(line),
                ),
              ),
            if (repo.settings.watchlist.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text('Nessuna linea ancora.'),
              ),

            const Divider(height: 32),
            const _SectionTitle('Chiave OpenRouter'),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                'Serve a leggere il testo degli avvisi. Il modello '
                'predefinito è gratuito, con un limite di 50 richieste al '
                'giorno. La chiave resta su questo dispositivo.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: _keyController,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                // Igiene per un campo che contiene una chiave: niente
                // correzione automatica, niente sostituzioni tipografiche.
                // Un trattino trasformato in apostrofo produrrebbe un 401
                // che sembra colpa dell'utente.
                smartDashesType: SmartDashesType.disabled,
                smartQuotesType: SmartQuotesType.disabled,
                keyboardType: TextInputType.visiblePassword,
                decoration: InputDecoration(
                  labelText: 'sk-or-v1-…',
                  border: const OutlineInputBorder(),
                  isDense: true,
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.save_outlined),
                    tooltip: 'Salva',
                    onPressed: () async {
                      final text = _keyController.text;
                      await repo.setApiKey(text);
                      if (!context.mounted) return;
                      final ok = Settings.looksLikeOpenRouterKey(text);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(ok
                              ? 'Chiave salvata'
                              : 'Salvata, ma non ha la forma di una chiave '
                                  'OpenRouter: controlla che i trattini '
                                  'siano trattini.'),
                          backgroundColor: ok
                              ? null
                              : Theme.of(context).colorScheme.error,
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text('Modello: ${repo.settings.model}',
                  style: Theme.of(context).textTheme.bodySmall),
            ),

            const Divider(height: 32),
            const _SectionTitle('Dati di GTT'),
            ListTile(
              leading: const Icon(Icons.download_outlined),
              title: const Text('Riscarica gli orari'),
              subtitle: const Text(
                  'Normalmente si aggiornano da soli ogni settimana.'),
              onTap: () {
                Navigator.pop(context);
                repo.initialise(forceDownload: true);
              },
            ),
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Dati: GTT S.p.A., licenza CC-BY. Mappe: OpenStreetMap. '
                'Percorsi calcolati con Valhalla (FOSSGIS), indirizzi con '
                'Photon.',
                style: TextStyle(fontSize: 11),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _addLine() async {
    final text = _lineController.text.trim();
    if (text.isEmpty) return;
    _lineController.clear();
    await widget.repo.addLine(text);
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Text(text,
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(color: Theme.of(context).colorScheme.primary)),
      );
}
