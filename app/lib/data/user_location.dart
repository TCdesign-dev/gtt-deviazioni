import 'dart:async';

import 'package:geolocator/geolocator.dart';

import '../core/geo/projection.dart';

/// Perche' non si sta mostrando la posizione.
///
/// Non e' un dettaglio di implementazione: i motivi si distinguono perche'
/// l'utente puo' fare qualcosa in due casi su tre, e dirgli genericamente
/// "posizione non disponibile" gli toglie la possibilita' di rimediare.
enum LocationDenial {
  /// Ha detto di no, ma glielo si puo' richiedere.
  rifiutata,

  /// Ha detto di no per sempre: da qui non si puo' piu' chiedere, si deve
  /// passare dalle impostazioni di sistema.
  rifiutataPerSempre,

  /// Il GPS del telefono e' spento del tutto.
  servizioSpento,

  /// Il permesso c'e' ma la posizione non arriva (al chiuso, appena
  /// acceso, simulatore senza posizione impostata).
  nessunSegnale,
}

/// Dove si trova chi sta guardando lo schermo.
///
/// Sta in `data/` e non in `core/` perche' usa un plugin Flutter, e
/// `core/` e' Dart puro: e' la regola che tiene in piedi tutto il resto.
///
/// La posizione **non lascia mai il telefono**. Non viene inviata a
/// nessun servizio, non viene salvata, non entra in nessuna richiesta di
/// rete: serve solo a disegnare un punto sulla mappa. Photon e Valhalla
/// ricevono i toponimi degli avvisi e il percorso della linea, mai dove
/// sei tu.
class UserLocation {
  /// Sotto questa soglia il punto non si muove: evita che il pallino
  /// balli da fermo per il rumore del GPS.
  static const _minMoveMeters = 8;

  StreamSubscription<Position>? _sub;

  /// Chiede il permesso se serve, e restituisce il motivo se non si puo'.
  ///
  /// Il permesso si chiede **quando l'utente tocca il pulsante**, non
  /// all'apertura della schermata: una richiesta che arriva senza che tu
  /// abbia chiesto niente si nega per riflesso.
  Future<LocationDenial?> ensurePermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return LocationDenial.servizioSpento;
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    return switch (permission) {
      LocationPermission.denied => LocationDenial.rifiutata,
      LocationPermission.deniedForever => LocationDenial.rifiutataPerSempre,
      _ => null,
    };
  }

  /// Un punto solo, subito.
  Future<GeoPoint?> current() async {
    try {
      final p = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 12),
        ),
      );
      return GeoPoint(p.latitude, p.longitude);
    } on Object {
      // Al chiuso o su un simulatore senza posizione impostata il GPS non
      // risponde: non e' un errore da mostrare come tale.
      return null;
    }
  }

  /// Il punto che si aggiorna mentre ti muovi.
  Stream<GeoPoint> follow() {
    return Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: _minMoveMeters,
      ),
    ).map((p) => GeoPoint(p.latitude, p.longitude));
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
  }

  /// Il messaggio da mostrare, che dice anche cosa si puo' fare.
  static String explain(LocationDenial d) => switch (d) {
        LocationDenial.rifiutata =>
          'Senza il permesso non posso mostrarti dove sei. '
              'Tocca di nuovo il pulsante per concederlo.',
        LocationDenial.rifiutataPerSempre =>
          'Il permesso è negato. Si riattiva da Impostazioni › '
              'Deviazioni GTT › Posizione.',
        LocationDenial.servizioSpento =>
          'La localizzazione del telefono è spenta.',
        LocationDenial.nessunSegnale =>
          'Non riesco a leggere la posizione: succede al chiuso. '
              'Riprova fra qualche secondo.',
      };
}
