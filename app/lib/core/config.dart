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
