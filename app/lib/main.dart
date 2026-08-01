import 'dart:async';

import 'package:flutter/material.dart';

import 'data/app_repository.dart';
import 'data/settings.dart';
import 'ui/home_screen.dart';
import 'ui/watch_banner.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = await Settings.load();
  final repo = AppRepository(settings);
  // L'avvio non blocca la prima schermata: il GTFS pesa 24 MB e l'utente
  // deve vedere l'avanzamento, non una pagina bianca.
  unawaited(repo.initialise());
  runApp(GttApp(repo: repo));
}

class GttApp extends StatelessWidget {
  const GttApp({required this.repo, super.key});

  final AppRepository repo;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DeviaTo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0B5FA5),
        ),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0B5FA5),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      // La striscia dell'osservazione sta QUI e non nelle schermate:
      // deve comparire sopra tutte, comprese quelle che ancora non
      // esistono, e nessuna di loro deve saperne niente.
      builder: (context, child) =>
          WatchBanner(repo: repo, child: child ?? const SizedBox.shrink()),
      home: HomeScreen(repo: repo),
    );
  }
}
