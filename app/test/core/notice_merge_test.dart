import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gtt_deviazioni/core/models/notice.dart';
import 'package:gtt_deviazioni/core/pipeline/notice_merge.dart';
import 'package:gtt_deviazioni/core/sources/alerts_source.dart';
import 'package:gtt_deviazioni/core/sources/variazioni_source.dart';

/// I testi di questo file sono avvisi VERI di GTT del 31/07/2026, copiati
/// dalle fixture. Non sono esempi addolciti: le coppie che qui devono
/// unirsi e quelle che devono restare separate sono le stesse su cui il
/// criterio e' stato tarato.
void main() {
  RawNotice alert(String headline, String text,
          {List<String> routes = const [],
          DateTime? from,
          DateTime? until,
          String? reason}) =>
      RawNotice(
        id: 'alert-x',
        source: NoticeSource.gtfsRtAlert,
        headline: headline,
        text: text,
        routeIds: routes,
        reason: reason,
        validFrom: from,
        validUntil: until,
        sourceUrl: 'alerts.aspx',
      );

  RawNotice tabella(String text,
          {String hint = '65',
          String? direzione,
          DateTime? from,
          DateTime? until,
          String? reason}) =>
      RawNotice(
        id: 'web-x',
        source: NoticeSource.webVariazioni,
        text: text,
        lineHints: [hint],
        directionHint: direzione,
        reason: reason,
        validFrom: from,
        validUntil: until,
        sourceUrl: 'cms/variazioni',
      );

  // ------------------------------------------------------------ la 65 -
  group('La 65 del 3 agosto: la stessa deviazione da due fonti', () {
    // Il caso visto dal vivo l'01/08/2026: la deviazione IREN di via
    // Lessona compariva due volte, e la copia dall'alert diceva "in
    // corso" mentre quella della tabella diceva "comincia il 3".
    final dalFeed = alert(
      'Linea 65 deviata in direzione corso Bolzano',
      'dalle 8:00 di lunedì 3 sino alle 18:00 di venerdì 7 agosto 2026.\n'
          'Da via Asinari di Bernezzo angolo corso Monte Grappa, per via '
          'Asinari di Bernezzo, piazza Chironi, via Medici, corso Lecce, '
          'via Lessona, segue percorso normale\n'
          'Causa lavori IREN teleriscaldamento in via Lessona angolo corso '
          'Monte Grappa.\n'
          'Dovranno essere osservate tutte le fermate esistenti sul '
          'percorso deviato.\n'
          'Inoltre, sarà istituita una fermata provvisoria in piazza '
          'Chironi, prima di via Domodossola.',
      routes: ['65U'],
      reason: 'OTHER_CAUSE',
      // MISURATO: e' l'ora di PUBBLICAZIONE, non l'inizio.
      from: DateTime(2026, 7, 31, 8, 16, 8),
      until: DateTime(2026, 8, 7, 16, 59),
    );
    final dallaTabella = tabella(
      'Da via Asinari di Bernezzo angolo corso Monte Grappa prosegue per '
          'via Asinari di Bernezzo, piazza Chironi, via Medici, corso '
          'Lecce, via Lessona, percorso normale.',
      direzione: 'corso Bolzano',
      reason: 'Lavori IREN per teleriscaldamento',
      from: DateTime(2026, 8, 3, 8, 0),
      until: DateTime(2026, 8, 7, 18, 0),
    );

    test('diventano un avviso solo', () {
      final out = NoticeMerge.dedupe([dalFeed, dallaTabella]);
      expect(out.length, equals(1));
      expect(out.single.isMerged, isTrue);
      expect(out.single.sources,
          equals({NoticeSource.gtfsRtAlert, NoticeSource.webVariazioni}));
    });

    test('LA COSA CHE CONTA: le date sono quelle della tabella', () {
      // Prima: l'avviso dell'alert risultava gia' attivo il 1° agosto,
      // perche' active_period.start era il 31 luglio — l'ora in cui GTT
      // ha pubblicato. Dopo l'unione la data e' quella vera.
      final unito = NoticeMerge.dedupe([dalFeed, dallaTabella]).single;
      final primoAgosto = DateTime(2026, 8, 1, 14, 30);

      expect(dalFeed.startsAfter(primoAgosto), isFalse, reason: 'il bug');
      expect(unito.startsAfter(primoAgosto), isTrue);
      expect(unito.daysUntilStart(primoAgosto), equals(2));
      expect(unito.validFrom, equals(DateTime(2026, 8, 3, 8, 0)));
      expect(unito.validUntil, equals(DateTime(2026, 8, 7, 18, 0)));
    });

    test('il testo mostrato e il piu completo dei due', () {
      // Qui e' quello dell'alert: dice anche la causa e la fermata
      // provvisoria di piazza Chironi, che nella tabella non ci sono.
      final unito = NoticeMerge.dedupe([dalFeed, dallaTabella]).single;
      expect(unito.text, contains('fermata provvisoria in piazza Chironi'));
      expect(unito.headline, equals(dalFeed.headline));
    });

    test('si tiene il meglio di ogni fonte', () {
      final unito = NoticeMerge.dedupe([dalFeed, dallaTabella]).single;
      // Il route_id canonico lo danno solo gli alert.
      expect(unito.routeIds, equals(['65U']));
      // La direzione e il motivo la tabella li ha in colonne separate:
      // "OTHER_CAUSE" non si mostra a nessuno.
      expect(unito.directionHint, equals('corso Bolzano'));
      expect(unito.reason, equals('Lavori IREN per teleriscaldamento'));
      expect(unito.lineHints, equals(['65']));
    });

    test('nessuno dei due originali va perso', () {
      final unito = NoticeMerge.dedupe([dalFeed, dallaTabella]).single;
      expect(unito.mergedFrom.length, equals(2));
      expect(unito.mergedFrom.map((n) => n.id),
          containsAll(<String>['alert-x', 'web-x']));
      // Anche il testo scartato resta leggibile per intero.
      expect(unito.allTexts.join(' '), contains('percorso normale.'));
    });

    test('l ordine di ingresso non cambia il risultato', () {
      final a = NoticeMerge.dedupe([dalFeed, dallaTabella]).single;
      final b = NoticeMerge.dedupe([dallaTabella, dalFeed]).single;
      expect(a.text, equals(b.text));
      expect(a.validFrom, equals(b.validFrom));
    });
  });

  // ------------------------------------------------------- il criterio -
  group('Quali vie nomina un avviso', () {
    test('prende i toponimi, non le parole a caso', () {
      expect(
        NoticeMerge.streetsIn(
            'Da via Asinari di Bernezzo angolo corso Monte Grappa'),
        equals({'asinari', 'bernezzo', 'monte', 'grappa'}),
      );
    });

    test('"lavori stradali" NON e una via', () {
      // La trappola gia' pagata: il confronto per sottostringhe faceva
      // scattare "lavori stradali" sul capolinea "STRADA del Drosso".
      // Qui "stradali" non segue nessun qualificatore, quindi non esiste.
      expect(NoticeMerge.streetsIn('deviata causa lavori stradali'), isEmpty);
      expect(NoticeMerge.streetsIn('Causa lavori stradali in via Bava'),
          equals({'bava'}));
    });

    test('il capolinea dopo "direzione" non e una via percorsa', () {
      // "Direzione via Moncalieri (Grugliasco)" dice DOVE VA il mezzo.
      // Contarla come via della deviazione fa somigliare fra loro tutte
      // le deviazioni della stessa linea nello stesso senso di marcia.
      expect(
        NoticeMerge.streetsIn('Direzione via Moncalieri (Grugliasco): da '
            'corso Vittorio Emanuele II angolo corso Inghilterra'),
        equals({'vittorio', 'emanuele', 'inghilterra'}),
      );
      // Anche con la preposizione in mezzo.
      expect(
        NoticeMerge.streetsIn(
            'Nella sola direzione di corso Cadore: da via Racagni'),
        equals({'racagni'}),
      );
    });

    test('i nomi di mese restano: via XX Settembre e una via vera', () {
      expect(
        NoticeMerge.streetsIn('Da via XX Settembre angolo via Santa Teresa'),
        equals({'settembre', 'santa', 'teresa'}),
      );
      // Ma una data non segue mai un qualificatore.
      expect(NoticeMerge.streetsIn('Da lunedi\' 13 luglio 2026 e sino a '
          'nuove comunicazioni'), isEmpty);
    });

    test('le cifre non distinguono niente', () {
      expect(NoticeMerge.streetsIn('corso Vittorio Emanuele II'),
          equals({'vittorio', 'emanuele'}));
      expect(NoticeMerge.streetsIn('la fermata n. 3445 in via Po'), isEmpty);
    });
  });

  // ------------------------------------------------- cosa NON si unisce -
  group('Cosa NON si unisce', () {
    test('due deviazioni diverse della stessa linea restano due', () {
      // Caso vero della 55: i lavori sui binari di luglio e la deviazione
      // del 3-7 agosto condividono solo il capolinea. Unirle vorrebbe
      // dire nasconderne una, e mostrare le date dell'altra.
      final binari = alert(
        'Linea 55 deviata in entrambe le direzioni',
        'dalle 08:30 di giovedì 23 luglio 2026 sino a nuove comunicazioni.\n'
            'Direzione via Moncalieri (Grugliasco): da corso Vittorio '
            'Emanuele II angolo corso Inghilterra, si instradano nella '
            'carreggiata laterale Nord di corso Vittorio Emanuele II e la '
            'percorrono sino all\'altezza di via Falcone.\n'
            'Direzione corso Farini: da corso Vittorio Emanuele II angolo '
            'via Borsellino, seguono la viabilità di cantiere predisposta.',
        routes: ['55U'],
        from: DateTime(2026, 6, 21, 10, 0),
      );
      final racconigi = tabella(
        'Dalle ore 15.00 a fine servizio. Direzione via Moncalieri '
            '(Grugliasco): da corso Vittorio Emanuele II deviata in piazza '
            'Adriano, via Di Nanni, piazza Sabotino, corso Peschiera, corso '
            'Racconigi, percorso normale. Direzione via Farini: da corso '
            'Racconigi deviata in corso Peschiera, piazza Sabotino, via Di '
            'Nanni, piazza Adriano, corso Vittorio Emanuele II, percorso '
            'attuale.',
        hint: '55',
        from: DateTime(2026, 8, 3),
        until: DateTime(2026, 8, 7),
      );

      expect(NoticeMerge.similarity(binari, racconigi), isNull);
      expect(NoticeMerge.dedupe([binari, racconigi]).length, equals(2));
    });

    test('un RIPRISTINO non si unisce alla variazione che chiude', () {
      // Caso vero della 14: l'alert annuncia il ritorno alla normalita' in
      // piazza Solferino, la tabella descrive ancora il capolinea
      // provvisorio. Stesso posto, cose opposte.
      final ripristino = alert(
        'Linea 14 ripristino percorso e capolinea',
        'Da martedi\' 7 luglio e sino a nuove comunicazioni\n'
            '• Direzione piazza Solferino: in piazza Solferino, dopo corso '
            'Re Umberto, effettua percorso e fermate regolari, inversione '
            'di marcia dopo la fontana Angelica, quindi prosegue in piazza '
            'Solferino nella corsia riservata sino in via Meucci.\n'
            'Causa lavori stradali in piazza Solferino.',
        routes: ['14U'],
      );
      final provvisorio = tabella(
        'Direzione piazza Solferino: effettuano capolinea provvisorio in '
            'piazza Solferino dopo corso Re Umberto, nell\'area lato est '
            'compresa tra via Alfieri e via Lascaris appositamente '
            'istituita. Direzioni via Amendola (Nichelino) – via '
            'Negarville: dal capolinea provvisorio di piazza Solferino '
            'dopo corso Re Umberto proseguono e effettuano inversione di '
            'marcia dopo la fontana Angelica.',
        hint: '14 - 63',
      );

      expect(NoticeMerge.similarity(ripristino, provvisorio), isNull);
      expect(NoticeMerge.dedupe([ripristino, provvisorio]).length, equals(2));
    });

    test('due avvisi della STESSA fonte non si toccano', () {
      // Anche identici. Senza l'altra fonte non c'e' nessuna data buona
      // da recuperare, e accorpare toglierebbe solo informazione.
      final a = alert('Linea 65 deviata',
          'Da via Lessona per piazza Chironi, via Medici, corso Lecce.');
      final b = alert('Linea 65 deviata',
          'Da via Lessona per piazza Chironi, via Medici, corso Lecce.');
      expect(NoticeMerge.dedupe([a, b]).length, equals(2));
    });

    test('un avviso che non nomina vie resta per conto suo', () {
      // Meglio un doppione visibile che una deviazione nascosta.
      final generico = alert('Linea 16CD gestita con autobus e deviata.',
          'Da sabato 1 agosto 2026 a domenica 13 settembre 2026.',
          routes: ['16CDU']);
      final dettagliato = tabella(
          'Gestita con autobus autosnodati con la seguente deviazione di '
              'percorso: da corso San Maurizio angolo via Bava prosegue per '
              'corso San Maurizio, lungo Po Cadorna, piazza Vittorio Veneto, '
              'via Bonafous, percorso normale.',
          hint: '16 CD');
      expect(NoticeMerge.similarity(generico, dettagliato), isNull);
      expect(NoticeMerge.dedupe([generico, dettagliato]).length, equals(2));
    });

    test('due periodi che non si toccano non sono la stessa cosa', () {
      final aprile = alert('Linea 9 deviata',
          'Da via Sempione per via Mercadante, via Gottardo, corso Vercelli.',
          from: DateTime(2026, 4, 1), until: DateTime(2026, 4, 30));
      final ottobre = tabella(
          'Da via Sempione deviata in via Mercadante, via Gottardo, corso '
              'Vercelli, percorso normale.',
          hint: '9',
          from: DateTime(2026, 10, 1),
          until: DateTime(2026, 10, 31));
      expect(NoticeMerge.similarity(aprile, ottobre), isNull);
    });
  });

  // ------------------------------------------------------- la scelta ---
  group('Quando la tabella somiglia a piu di un alert', () {
    // Caso vero della S45: due alert, "marrone" e "notturna estiva",
    // descrivono la stessa deviazione a Chieri con dettaglio diverso. La
    // riga della tabella deve unirsi al piu' simile, non al primo.
    final estiva = alert(
      'Linea S45 "notturna estiva" deviata in direzione Chieri',
      'Da strada Cambiano per via Diaz angolo via Battisti percorso '
          'regolare.\nCausa lavori in via Roma a Chieri',
      routes: ['S45U'],
    );
    final marrone = alert(
      'Linea S45 marrone deviata in direzione Chieri',
      'Da venerdi\' 10 luglio e sino a nuove comunicazioni.\n'
          'Da strada Cambiano angolo via Roma per via Diaz, via Cesare '
          'Battisti, piazza Europa, segue percorso regolare.\n'
          'Causa lavori stradali nel comune di Chieri.',
      routes: ['S45U'],
    );
    final riga = tabella(
      'Nel Comune di Chieri. Da strada Cambiano angolo via Roma deviata in '
          'via Diaz, via Cesare Battisti, piazza Europa, percorso normale.',
      hint: 'S45 MARRONE',
      from: DateTime(2026, 7, 10),
    );

    test('si unisce al piu simile, non al primo che capita', () {
      expect(NoticeMerge.similarity(estiva, riga)!,
          lessThan(NoticeMerge.similarity(marrone, riga)!));

      // L'ordine e' quello sfavorevole: l'alert meno simile viene prima.
      final out = NoticeMerge.dedupe([estiva, marrone, riga]);
      expect(out.length, equals(2));
      final unito = out.firstWhere((n) => n.isMerged);
      expect(unito.text, contains('piazza Europa, segue percorso regolare'));
      expect(out.where((n) => !n.isMerged).single.headline,
          contains('notturna estiva'));
    });

    test('un avviso finisce in una coppia sola', () {
      final out = NoticeMerge.dedupe([estiva, marrone, riga]);
      final usati = out.expand((n) => n.isMerged ? n.mergedFrom : [n]).toList();
      expect(usati.length, equals(3));
      expect(usati.map((n) => n.id).toSet().length, equals(2)); // gli id di test
    });
  });

  // ----------------------------------------------------- dati completi -
  group('Il testo piu completo non e sempre quello dell alert', () {
    test('sulla 4 la tabella descrive tutto il percorso delle navette', () {
      final corto = alert(
        'Linea 4 limitata in piazza Derna',
        'da lunedi\' 25 agosto 2025 e sino a nuove comunicazioni. La tratta '
            'da piazza Derna a Falchera verrà gestita con autobus '
            'sostitutivi. Causa lavori in corso Giulio Cesare e via delle '
            'Querce.',
        routes: ['4U'],
        from: DateTime(2025, 8, 25, 22, 0),
      );
      final lungo = tabella(
        'Tram limitati in corso Giulio Cesare angolo piazza Derna '
            '(capolinea provvisorio). Navette bus sostitutive saranno in '
            'servizio sul tratto temporaneamente non servito dai tram: via '
            'delle Querce (Falchera) - largo Donatori di Sangue (fermata n. '
            '225). Percorso: dal capolinea di via delle Querce prosegue per '
            'via delle Robinie, piazza Astengo, via dei Frassini, viale '
            'Falchera, corso Vercelli, piazzale Autostrade, corso Giulio '
            'Cesare, via Porpora, via Monte Rosa, via Sempione, via '
            'Mercadante, via Gottardo, via Monte Rosa, piazza Derna.',
        hint: '4',
        from: DateTime(2025, 8, 25),
      );

      final unito = NoticeMerge.dedupe([corto, lungo]).single;
      expect(unito.text, contains('via delle Robinie'));
      // Il titolo segue il testo scelto: qui la tabella non ne ha.
      expect(unito.headline, isNull);
      // E il codice fermata scritto solo li' non si perde.
      expect(unito.suspendedStopCodes, contains('225'));
    });

    test('i codici fermata si leggono in tutti e due i testi', () {
      // Il testo che non viene mostrato puo' contenere l'unico dato
      // davvero certo che il sistema abbia: un numero di fermata scritto
      // da GTT. Non deve sparire per una scelta di impaginazione.
      final conSospesa = alert('Linea 19 deviata',
          'La fermata n. 2080 denominata "Poliziano" sita in via Ravina e\' '
              'sospesa. Da via Poliziano per lungo Dora Colletta, via '
              'Carcano.',
          routes: ['19U']);
      final conCapolinea = tabella(
          'Da via Poliziano deviata in lungo Dora Colletta, via Carcano, '
              'via Ravina, con capolinea provvisorio presso la fermata '
              'n.1182, percorso normale.',
          hint: '19');
      final unito = NoticeMerge.dedupe([conCapolinea, conSospesa]).single;
      expect(unito.suspendedStopCodes, containsAll(<String>['2080', '1182']));
    });
  });

  // ------------------------------------------------------- dati veri ---
  group('Sulle fixture vere del 31/07/2026', () {
    late List<RawNotice> alerts;
    late List<RawNotice> web;

    setUpAll(() {
      alerts = AlertsSource()
          .parse(File('test/fixtures/alerts.pb').readAsBytesSync());
      web = VariazioniSource()
          .parse(File('test/fixtures/variazioni.html').readAsStringSync());
    });

    test('la coppia della 65 si riconosce sui dati non toccati', () {
      final a = alerts.firstWhere((n) => n.routeIds.contains('65U') &&
          n.fullText.contains('Lessona'));
      final w = web.firstWhere((n) =>
          n.lineHints.first == '65' && n.fullText.contains('Lessona'));

      expect(NoticeMerge.similarity(a, w), equals(1.0));
      final unito = NoticeMerge.dedupe([a, w]).single;
      expect(unito.validFrom, equals(DateTime(2026, 8, 3, 8, 0)));
      expect(unito.startsAfter(DateTime(2026, 8, 1)), isTrue);
    });

    test('nessun avviso si perde e nessuno si usa due volte', () {
      // Sulla lista intera: quello che entra deve uscire, o da solo o
      // dentro esattamente un avviso unito.
      final tutti = [...alerts, ...web];
      final out = NoticeMerge.dedupe(tutti);
      final originali =
          out.expand((n) => n.isMerged ? n.mergedFrom : [n]).toList();
      expect(originali.length, equals(tutti.length));
      expect(originali.map((n) => n.id).toSet().length, equals(tutti.length));
    });

    test('ogni coppia unita ha davvero due fonti diverse', () {
      final out = NoticeMerge.dedupe([...alerts, ...web]);
      for (final n in out.where((n) => n.isMerged)) {
        expect(n.sources.length, equals(2), reason: n.id);
      }
    });
  });

  group('L apostrofo finale di GTT', () {
    test('"lunedi\'" non diventa un nome di via', () {
      // GTT scrive "da lunedi' 25 agosto" molto piu' spesso di "lunedì".
      // La lista dei non-nomi conteneva solo le forme accentate, quindi
      // il giorno della settimana finiva fra i toponimi.
      final vie = NoticeMerge.streetsIn(
          "Linea 4 limitata in piazza Derna da lunedi' 25 agosto 2025.");
      expect(vie, contains('derna'));
      expect(vie, isNot(contains("lunedi'")));
      expect(vie, isNot(contains('lunedi')));
    });

    test('tutti i giorni con apostrofo', () {
      for (final g in ["martedi'", "mercoledi'", "giovedi'", "venerdi'"]) {
        final vie = NoticeMerge.streetsIn('deviata in corso Regina da $g 3.');
        expect(vie, isNot(contains(g)), reason: g);
        expect(vie, contains('regina'), reason: g);
      }
    });

    test('una via che finisce per apostrofo resta se stessa', () {
      // Non esistono vie che finiscono con l'apostrofo, ma se il testo
      // ne avesse una fra virgolette non deve sparire.
      expect(NoticeMerge.streetsIn("corso Cuorgne' angolo via Roma"),
          contains('cuorgne'));
    });
  });
}
