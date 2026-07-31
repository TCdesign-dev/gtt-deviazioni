/// Tutte le costanti tarabili del sistema, in un posto solo.
///
/// Sono qui e non sparse nel codice perche' quasi tutte vanno tarate sul
/// campo, e quando lo farai vorrai un file solo da aprire.
///
/// I valori marcati MISURATO vengono da rilevazioni vere del 31/07/2026
/// (vedi docs/FASE-0-RISULTATI.md), non dalle stime della specifica.
library;

class GttConfig {
  const GttConfig._();

  // ---------------------------------------------------------------- fonti

  static const gtfsZipUrl = 'https://www.gtt.to.it/open_data/gtt_gtfs.zip';
  static const alertsUrl =
      'https://percorsieorari.gtt.to.it/das_gtfsrt/alerts.aspx';
  static const vehiclesUrl =
      'https://percorsieorari.gtt.to.it/das_gtfsrt/vehicle_position.aspx';
  static const variazioniUrl = 'https://gtt.to.it/cms/variazioni';

  /// Geocoder OSM pubblico, nessuna chiave.
  /// ATTENZIONE: NON passare lang=it — Photon supporta solo default/de/en/fr
  /// e risponde 400, in modo silenzioso se non si controlla lo status.
  static const photonUrl = 'https://photon.komoot.io/api';

  /// Valhalla pubblico di FOSSGIS. Accetta costing "bus", che rispetta
  /// sensi unici e divieti per mezzi pesanti (OSRM "car" no).
  /// E' un servizio di cortesia: nessuna garanzia, serve sempre il ripiego.
  static const valhallaUrl = 'https://valhalla1.openstreetmap.de/route';

  /// Identificati verso GTT: se vogliono contattarti devono poterlo fare.
  static const userAgent =
      'gtt-deviazioni/1.0 (app personale; contatto: tommasocostanza7@gmail.com)';

  // ------------------------------------------------------------ geografia

  /// Latitudine di riferimento per la proiezione locale (Torino).
  static const refLatitude = 45.07;

  /// Riquadro del bacino GTT. Serve a scartare le posizioni spazzatura:
  /// MISURATO, ~3% dei mezzi pubblica lat=0 lon=0 (Null Island). Senza
  /// questo filtro sono 5.000 km di "fuori rotta" e un falso positivo certo.
  static const bboxMinLat = 44.5;
  static const bboxMaxLat = 45.6;
  static const bboxMinLon = 7.0;
  static const bboxMaxLon = 8.3;

  // ------------------------------------------------------------- soglie

  /// Quanto lontano dal percorso teorico puo' stare un toponimo geocodificato
  /// prima di considerarlo sbagliato.
  ///
  /// MISURATO su 150 toponimi di avvisi reali: quelli corretti stanno entro
  /// 800 m dal percorso, il primo falso (una via di Torino estranea alla
  /// linea) a 1342 m. La specifica proponeva 2 km: troppo larghi, ci passa
  /// spazzatura. A 500 m si scartano vie legittime, perche' una deviazione
  /// per definizione si allontana dal percorso normale.
  static const geocodeBufferMeters = 1000.0;

  /// Distanza oltre la quale un mezzo e' considerato fuori percorso.
  ///
  /// MISURATO su 349 mezzi: distanza dal percorso teorico con mediana 3,6 m,
  /// 99° percentile 28 m, massimo 65 m una volta scartate le posizioni
  /// spazzatura. La specifica proponeva 80 m per prudenza: il GPS di GTT e'
  /// molto piu' pulito del previsto, 50 m lasciano gia' un margine ampio.
  static const offRouteMeters = 50.0;

  /// Oltre questa distanza dal percorso deviato, una fermata e' saltata.
  /// Dalla specifica §6.1, non ancora verificato sul campo.
  static const stopSkippedMeters = 40.0;

  /// Raggio entro cui cercare fermate alternative a una saltata.
  static const alternativeStopMeters = 400.0;

  // ------------------------------------------------- validazione percorso

  /// Le cinque prove di §5.2.3 su un percorso ricostruito. Se una fallisce,
  /// il percorso NON va mostrato come certo: meglio nessuna mappa che una
  /// mappa sbagliata, perche' un falso positivo fa perdere il bus.

  /// Quanto puo' distare l'inizio del percorso calcolato dal punto di
  /// stacco dichiarato nell'avviso.
  static const routeStartToleranceMeters = 200.0;

  /// Idem per il punto di ricongiungimento.
  static const routeEndToleranceMeters = 200.0;

  /// Il percorso calcolato deve passare almeno cosi' vicino a OGNI via
  /// nominata nell'avviso. Se ne salta una, ha preso un'altra strada.
  static const routeViaToleranceMeters = 100.0;

  /// Rapporto massimo fra la deviazione e il **tratto di percorso normale
  /// che sostituisce**.
  ///
  /// La specifica confrontava con la distanza in linea d'aria fra stacco e
  /// rientro. MISURATO: non funziona, perche' molte deviazioni sono anelli
  /// che rientrano vicino al punto di stacco — la 2C fa 4,3 km per 0,8 km
  /// in linea d'aria e verrebbe bocciata pur essendo corretta. Il
  /// confronto giusto e' con il pezzo di percorso che la deviazione
  /// rimpiazza.
  static const routeMaxDetourRatio = 3.0;

  /// Lunghezza minima del tratto realmente fuori percorso.
  ///
  /// Sostituisce la regola "max 20% di sovrapposizione col percorso
  /// normale" della specifica. MISURATO: non regge, perche' moltissimi
  /// avvisi dicono "prosegue per la stessa via" e la deviazione condivide
  /// strada col percorso normale per costruzione — le tre deviazioni reali
  /// provate condividevano il 36%, 38% e 66%, ed erano tutte corrette.
  ///
  /// Quello che conta davvero e' che esista un tratto CONTINUO fuori
  /// percorso: e' cio' che distingue una deviazione vera da un percorso
  /// che coincide con quello normale (il falso positivo di §11.4).
  static const routeMinDetourMeters = 150.0;

  /// Entro questa distanza un punto e' considerato "sul percorso normale",
  /// per il calcolo della sovrapposizione qui sopra.
  static const routeOverlapMeters = 30.0;

  /// Passo di campionamento per le verifiche geometriche sul percorso.
  static const routeSampleMeters = 25.0;

  // -------------------------------------------------- punto di rientro

  /// Quanto puo' distare dal percorso l'ultima via nominata perche' se ne
  /// possa dedurre il punto di rientro.
  ///
  /// MISURATO sui 22 casi reali con rientro non dichiarato: mediana 1 m,
  /// 75° percentile 2 m, 21 su 22 entro 100 m. L'unico fuori scala e' la
  /// linea 7 con "corso Vittorio Emanuele II" a 310 m — via lunghissima,
  /// dove il geocoder da' un punto solo che cade lontano da dove la linea
  /// la incontra. La soglia sta apposta sotto quel valore: quel caso NON
  /// va dedotto, va dichiarato ignoto.
  static const rejoinMaxViaDistanceMeters = 300.0;

  /// Quanto avanti allo stacco deve stare il rientro. Serve a non far
  /// coincidere i due punti su percorsi che ripassano vicino a se stessi.
  static const rejoinMinForwardMeters = 100.0;

  // -------------------------------------------------------------- burst

  /// Finestra di osservazione GPS on-demand. Adattiva: ci si ferma appena
  /// si hanno abbastanza mezzi, e si molla dopo il massimo dichiarando
  /// "nessun mezzo osservato" — che NON significa "nessuna deviazione".
  static const burstPollInterval = Duration(seconds: 30);
  static const burstMaxDuration = Duration(minutes: 15);

  /// Quanti mezzi distinti servono per dire "confermato".
  /// Due bastano quando c'e' gia' un'ipotesi dal testo da verificare:
  /// non stai scoprendo da zero, stai controllando una previsione.
  static const burstMinVehicles = 2;

  // ---------------------------------------------------------------- rete

  static const httpTimeout = Duration(seconds: 30);

  /// Pausa minima fra chiamate ai servizi pubblici gratuiti.
  /// Photon e Valhalla sono servizi di cortesia: non vanno martellati.
  static const publicApiDelay = Duration(milliseconds: 400);

  /// Il percorso teorico cambia di rado; le deviazioni arrivano dagli alert,
  /// che pesano 210 KB. Non serve riscaricare 24 MB ogni giorno.
  static const gtfsRefreshInterval = Duration(days: 7);
}
