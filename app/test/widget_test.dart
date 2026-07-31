import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gtt_deviazioni/data/app_repository.dart';
import 'package:gtt_deviazioni/data/settings.dart';
import 'package:gtt_deviazioni/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// L'interfaccia deve dire all'utente cosa sta succedendo e cosa manca,
/// senza schermate bianche e senza gerghi.
void main() {
  Future<AppRepository> repoWith(Map<String, Object> prefs) async {
    SharedPreferences.setMockInitialValues(prefs);
    return AppRepository(await Settings.load());
  }

  testWidgets('senza linee spiega cosa fare, invece di restare vuota',
      (tester) async {
    final repo = await repoWith({});
    await repo.initialise();
    await tester.pumpWidget(GttApp(repo: repo));
    await tester.pump();

    expect(find.text('Nessuna linea'), findsOneWidget);
    expect(find.text('Aggiungi una linea'), findsOneWidget);
  });

  testWidgets('durante il caricamento mostra l avanzamento, non una pagina '
      'bianca', (tester) async {
    final repo = await repoWith({'watchlist': <String>['55']});
    await tester.pumpWidget(GttApp(repo: repo));
    await tester.pump();

    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });

  testWidgets('la schermata impostazioni si apre dalla home', (tester) async {
    final repo = await repoWith({});
    await repo.initialise();
    await tester.pumpWidget(GttApp(repo: repo));
    await tester.pump();

    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();

    expect(find.text('Impostazioni'), findsOneWidget);
    expect(find.text('Le tue linee'), findsOneWidget);
    expect(find.text('Chiave OpenRouter'), findsOneWidget);
  });

  testWidgets('si puo aggiungere una linea dalle impostazioni',
      (tester) async {
    final repo = await repoWith({});
    await repo.initialise();
    await tester.pumpWidget(GttApp(repo: repo));
    await tester.pump();

    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '55');
    await tester.tap(find.text('Aggiungi'));
    await tester.pump();

    expect(repo.settings.watchlist, contains('55'));
  });

  test('la stessa linea non si aggiunge due volte', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = await Settings.load();
    await settings.addLine('55');
    await settings.addLine('55');
    await settings.addLine(' 55 ');
    expect(settings.watchlist, equals(['55']));
  });

  test('riconosce una chiave con i trattini alterati', () {
    // Una sostituzione tipografica dei trattini produce un 401 identico
    // a quello di una chiave sbagliata: meglio dirlo prima.
    expect(
        Settings.looksLikeOpenRouterKey(
            'sk-or-v1-d6b778760354d66bab1c7677e02050141980edc'),
        isTrue);
    expect(
        Settings.looksLikeOpenRouterKey(
            "sk'or'v1'd6b778760354d66bab1c7677e02050141980edc"),
        isFalse);
    expect(Settings.looksLikeOpenRouterKey('sk-or-v1-'), isFalse);
    expect(Settings.looksLikeOpenRouterKey(''), isFalse);
  });

  test('la chiave si salva e si rilegge', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = await Settings.load();
    expect(settings.hasApiKey, isFalse);
    await settings.setApiKey('  sk-or-v1-prova  ');
    expect(settings.apiKey, equals('sk-or-v1-prova'));
    expect(settings.hasApiKey, isTrue);
  });
}
