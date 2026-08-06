import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gtt_deviazioni/ui/line_tile.dart';

/// Mezzo minuto davanti a una rotella che gira e basta e' indistinguibile
/// da un'app bloccata. Questi test tengono ferma la differenza.
///
/// Si verificano qui e non a schermo perche' lo stato dura pochi secondi:
/// fotografarlo e' una gara che si perde.
void main() {
  Widget schermo(Widget child) => MaterialApp(
    home: Scaffold(body: ListView(children: [child])),
  );

  testWidgets('mentre controlla mostra la barra e a che punto e', (
    tester,
  ) async {
    await tester.pumpWidget(
      schermo(
        const LineTile(
          shortName: '65',
          status: null,
          watching: false,
          watchedVehicles: 0,
          checkedAt: null,
          checking: true,
          phase: 'avviso 2 di 4: cerco «corso Lecce» sulla mappa',
          onCheck: _niente,
        ),
      ),
    );

    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.textContaining('avviso 2 di 4'), findsOneWidget);
    expect(find.textContaining('corso Lecce'), findsOneWidget);
  });

  testWidgets('senza fase non resta muta', (tester) async {
    // Puo' capitare fra un passaggio e l'altro: meglio "controllo..." che
    // una riga vuota sotto una barra che scorre.
    await tester.pumpWidget(
      schermo(
        const LineTile(
          shortName: '65',
          status: null,
          watching: false,
          watchedVehicles: 0,
          checkedAt: null,
          checking: true,
          phase: null,
          onCheck: _niente,
        ),
      ),
    );

    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('controllo in corso…'), findsOneWidget);
  });

  testWidgets('il riassunto vecchio sparisce mentre si ricontrolla', (
    tester,
  ) async {
    // Lasciare "2 fermate non servite" mentre si sta ricalcolando
    // significa mostrare un dato che potrebbe non essere piu' vero.
    await tester.pumpWidget(
      schermo(
        const LineTile(
          shortName: '65',
          status: null,
          watching: false,
          watchedVehicles: 0,
          checkedAt: null,
          checking: true,
          phase: 'interpreto il testo',
          onCheck: _niente,
        ),
      ),
    );

    expect(find.text('Da controllare'), findsNothing);
  });

  testWidgets('a riposo niente barra, e si vede lo stato', (tester) async {
    await tester.pumpWidget(
      schermo(
        const LineTile(
          shortName: '65',
          status: null,
          watching: false,
          watchedVehicles: 0,
          checkedAt: null,
          checking: false,
          phase: null,
          onCheck: _niente,
        ),
      ),
    );

    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text('Da controllare'), findsOneWidget);
  });

  testWidgets('mentre controlla non si puo far ripartire il controllo', (
    tester,
  ) async {
    var tocchi = 0;
    await tester.pumpWidget(
      schermo(
        LineTile(
          shortName: '65',
          status: null,
          watching: false,
          watchedVehicles: 0,
          checkedAt: null,
          checking: true,
          phase: 'interpreto il testo',
          onCheck: () => tocchi++,
        ),
      ),
    );

    // Il pulsante e' sostituito dall'indicatore: non c'e' niente da
    // toccare, e due controlli in parallelo sprecherebbero quota.
    expect(find.byIcon(Icons.refresh), findsNothing);
    expect(tocchi, isZero);
  });

  testWidgets('mentre guarda i mezzi lo dice, anche fuori dal dettaglio', (
    tester,
  ) async {
    // L'osservazione continua uscendo dalla schermata della linea: se qui
    // non si vedesse, uno la lascerebbe girare senza sapere che e' accesa.
    await tester.pumpWidget(
      schermo(
        const LineTile(
          shortName: '15',
          status: null,
          watching: true,
          watchedVehicles: 3,
          checkedAt: null,
          checking: false,
          phase: null,
          onCheck: _niente,
        ),
      ),
    );

    expect(find.text('3 mezzi in osservazione'), findsOneWidget);
    expect(find.byIcon(Icons.directions_bus), findsOneWidget);
    // Prende il posto del riassunto: quello non e' cio' che sta
    // succedendo adesso.
    expect(find.text('Da controllare'), findsNothing);
  });

  testWidgets('un mezzo solo si dice al singolare', (tester) async {
    await tester.pumpWidget(
      schermo(
        const LineTile(
          shortName: '15',
          status: null,
          watching: true,
          watchedVehicles: 1,
          checkedAt: null,
          checking: false,
          phase: null,
          onCheck: _niente,
        ),
      ),
    );
    expect(find.text('1 mezzo in osservazione'), findsOneWidget);
  });

  testWidgets('prima di vedere qualcosa non dice "zero mezzi"', (tester) async {
    await tester.pumpWidget(
      schermo(
        const LineTile(
          shortName: '15',
          status: null,
          watching: true,
          watchedVehicles: 0,
          checkedAt: null,
          checking: false,
          phase: null,
          onCheck: _niente,
        ),
      ),
    );
    expect(find.text('osservazione in corso…'), findsOneWidget);
  });
}

void _niente() {}
