import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../config.dart';

/// Client HTTP condiviso verso GTT e i servizi pubblici.
///
/// Esiste per due motivi che valgono piu' della comodita':
/// 1. lo User-Agent identificabile e' una questione di correttezza — GTT,
///    Photon e Valhalla offrono questi dati gratuitamente e devono poter
///    capire chi li sta usando (§Appendice B);
/// 2. la pausa fra chiamate ai servizi gratuiti evita di farsi bloccare.
class GttHttp {
  GttHttp({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;
  DateTime? _lastPublicCall;

  Future<Uint8List> getBytes(String url) async {
    final r = await _get(url);
    return r.bodyBytes;
  }

  Future<String> getText(String url) async {
    final r = await _get(url);
    return r.body;
  }

  /// Come [getText], ma rispetta una pausa minima fra una chiamata e
  /// l'altra. Da usare per Photon e Valhalla, che sono servizi di cortesia.
  Future<String> getTextPolite(String url) async {
    final last = _lastPublicCall;
    if (last != null) {
      final elapsed = DateTime.now().difference(last);
      if (elapsed < GttConfig.publicApiDelay) {
        await Future<void>.delayed(GttConfig.publicApiDelay - elapsed);
      }
    }
    _lastPublicCall = DateTime.now();
    return getText(url);
  }

  Future<http.Response> _get(String url) async {
    final http.Response r;
    try {
      r = await _client
          .get(Uri.parse(url), headers: {'User-Agent': GttConfig.userAgent})
          .timeout(GttConfig.httpTimeout);
    } on Object catch (e) {
      throw GttHttpException(url, null, 'rete non raggiungibile: $e');
    }
    if (r.statusCode != 200) {
      // Il corpo dell'errore va conservato: Photon per esempio spiega nel
      // body perche' ha rifiutato, e senza guardarlo il fallimento sembra
      // "nessun risultato" invece di "richiesta sbagliata".
      throw GttHttpException(url, r.statusCode, _snippet(r.body));
    }
    return r;
  }

  static String _snippet(String body) =>
      body.length <= 200 ? body : '${body.substring(0, 200)}...';

  void close() => _client.close();
}

class GttHttpException implements Exception {
  GttHttpException(this.url, this.statusCode, this.detail);

  final String url;
  final int? statusCode;
  final String detail;

  @override
  String toString() =>
      'GttHttpException(${statusCode ?? "-"}) $url: $detail';
}
