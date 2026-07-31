import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';
import 'llm_client.dart';

/// Gemini via API diretta.
///
/// Scelto come predefinito per una ragione tecnica, non per il prezzo:
/// supporta `responseSchema`, cioe' la risposta e' **garantita** conforme
/// allo schema. Per un compito di estrazione che deve poi essere validato
/// (§5.2.1), toglie di mezzo tutta la casistica "ha risposto con del testo
/// attorno al JSON", che e' il fallimento piu' frequente.
///
/// La chiave sta sul dispositivo: da un'app mobile si puo' estrarre.
/// Per uso personale va bene, ma metti un tetto di spesa sul fornitore e
/// non pubblicare l'app con la chiave dentro.
class GeminiClient implements LlmClient {
  GeminiClient({
    required this.apiKey,
    this.model = 'gemini-flash-latest',
    http.Client? client,
  }) : _client = client ?? http.Client();

  final String apiKey;
  final String model;
  final http.Client _client;

  @override
  String get name => 'gemini/$model';

  @override
  Future<String> complete(
    String prompt, {
    Map<String, dynamic>? jsonSchema,
  }) async {
    final uri = Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/models/'
        '$model:generateContent');

    final body = <String, dynamic>{
      'contents': [
        {
          'parts': [
            {'text': prompt}
          ]
        }
      ],
      'generationConfig': {
        // Estrazione, non creativita'.
        'temperature': 0,
        if (jsonSchema != null) ...{
          'responseMimeType': 'application/json',
          'responseSchema': jsonSchema,
        },
      },
    };

    final http.Response r;
    try {
      r = await _client
          .post(uri,
              headers: {
                'Content-Type': 'application/json',
                'x-goog-api-key': apiKey,
              },
              body: jsonEncode(body))
          .timeout(GttConfig.httpTimeout);
    } on Object catch (e) {
      throw LlmException(name, 'rete non raggiungibile: $e');
    }

    if (r.statusCode != 200) {
      throw LlmException(name, _snippet(r.body), statusCode: r.statusCode);
    }

    try {
      final json = jsonDecode(r.body) as Map<String, dynamic>;
      final candidates = json['candidates'] as List?;
      if (candidates == null || candidates.isEmpty) {
        throw LlmException(name, 'nessuna risposta: ${_snippet(r.body)}');
      }
      final parts = ((candidates.first as Map<String, dynamic>)['content']
          as Map<String, dynamic>?)?['parts'] as List?;
      final text = (parts?.first as Map<String, dynamic>?)?['text'] as String?;
      if (text == null) {
        throw LlmException(name, 'risposta senza testo: ${_snippet(r.body)}');
      }
      return text;
    } on LlmException {
      rethrow;
    } on Object catch (e) {
      throw LlmException(name, 'risposta illeggibile: $e');
    }
  }

  static String _snippet(String s) =>
      s.length <= 300 ? s : '${s.substring(0, 300)}...';
}
