import 'dart:async';

import 'package:flutter/material.dart';

import 'data/app_repository.dart';
import 'data/settings.dart';
import 'ui/home_screen.dart';

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
      title: 'Deviazioni GTT',
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
      home: HomeScreen(repo: repo),
    );
  }
}
