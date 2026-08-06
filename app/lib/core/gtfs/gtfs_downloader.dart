import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:http/http.dart' as http;

import '../config.dart';

/// Scarica il GTFS di GTT e ne estrae i file che servono.
///
/// Il pezzo che mancava perche' l'app potesse funzionare da sola: il
/// parser legge da una cartella, ma quella cartella non la riempiva
/// nessuno.
///
/// Due accortezze che contano sul telefono:
/// - si estrae **un file alla volta in streaming**, senza decomprimere
///   tutto in memoria: `stop_times.txt` da solo pesa 140 MB decompressi;
/// - non si riscarica ogni giorno. Il percorso teorico cambia di rado,
///   mentre le deviazioni arrivano dagli alert che pesano 210 KB.
class GtfsDownloader {
  GtfsDownloader({required this.directory, http.Client? client})
      : _client = client ?? http.Client();

  /// Dove finiscono i .txt estratti.
  final Directory directory;
  final http.Client _client;

  /// I soli file che il parser usa. Gli altri (timetables, fare_rules,
  /// vehicles...) sono megabyte che non servono a nulla qui.
  static const neededFiles = [
    'feed_info.txt',
    'routes.txt',
    'trips.txt',
    'shapes.txt',
    'stops.txt',
    'stop_times.txt',
  ];

  File get _stamp => File('${directory.path}/.scaricato');

  /// Quando e' stato scaricato l'ultima volta, null se mai.
  DateTime? get lastDownload {
    if (!_stamp.existsSync()) return null;
    return DateTime.tryParse(_stamp.readAsStringSync().trim());
  }

  bool get isPresent =>
      neededFiles.every((f) => File('${directory.path}/$f').existsSync());

  /// Serve riscaricare?
  bool get isStale {
    if (!isPresent) return true;
    final last = lastDownload;
    if (last == null) return true;
    return DateTime.now().difference(last) > GttConfig.gtfsRefreshInterval;
  }

  /// Scarica ed estrae, se serve. [onProgress] riceve una frase leggibile
  /// e un avanzamento 0..1: un'attesa muta di trenta secondi sembra un
  /// blocco.
  Future<void> ensureAvailable({
    bool force = false,
    void Function(String phase, double fraction)? onProgress,
  }) async {
    if (!force && !isStale) return;

    directory.createSync(recursive: true);
    final zip = File('${directory.path}/gtt_gtfs.zip');

    onProgress?.call('Scaricamento orari GTT', 0.0);
    await _download(zip, onProgress);

    onProgress?.call('Estrazione dei dati', 0.75);
    _extract(zip);

    // Lo zip non serve piu': sono 24 MB sul telefono.
    if (zip.existsSync()) zip.deleteSync();

    _stamp.writeAsStringSync(DateTime.now().toIso8601String());
    onProgress?.call('pronto', 1.0);
  }

  Future<void> _download(
    File dest,
    void Function(String, double)? onProgress,
  ) async {
    final request = http.Request('GET', Uri.parse(GttConfig.gtfsZipUrl))
      ..headers['User-Agent'] = GttConfig.userAgent;

    final http.StreamedResponse response;
    try {
      response = await _client.send(request).timeout(
            const Duration(minutes: 5),
          );
    } on Object catch (e) {
      throw GtfsDownloadException('scaricamento non riuscito: $e');
    }
    if (response.statusCode != 200) {
      throw GtfsDownloadException(
          'GTT ha risposto ${response.statusCode}');
    }

    final total = response.contentLength ?? 0;
    var received = 0;
    final sink = dest.openWrite();
    try {
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) {
          // Lo scaricamento vale il 75% dell'attesa complessiva.
          onProgress?.call('Scaricamento orari GTT',
              0.75 * received / total);
        }
      }
    } finally {
      await sink.close();
    }
  }

  void _extract(File zip) {
    final input = InputFileStream(zip.path);
    try {
      final archive = ZipDecoder().decodeStream(input);
      for (final file in archive.files) {
        if (!file.isFile) continue;
        final name = file.name.split('/').last;
        if (!neededFiles.contains(name)) continue;

        // In streaming: decomprimere stop_times.txt in memoria vorrebbe
        // dire 140 MB in RAM su un telefono.
        final out = OutputFileStream('${directory.path}/$name');
        try {
          file.writeContent(out);
        } finally {
          out.closeSync();
        }
      }
    } on GtfsDownloadException {
      rethrow;
    } on Object catch (e) {
      throw GtfsDownloadException('estrazione non riuscita: $e');
    } finally {
      input.closeSync();
    }

    final missing = neededFiles
        .where((f) => !File('${directory.path}/$f').existsSync())
        .toList();
    if (missing.isNotEmpty) {
      throw GtfsDownloadException(
          'nello zip mancano: ${missing.join(", ")}');
    }
  }
}

class GtfsDownloadException implements Exception {
  GtfsDownloadException(this.message);

  final String message;

  @override
  String toString() => 'GtfsDownloadException: $message';
}
