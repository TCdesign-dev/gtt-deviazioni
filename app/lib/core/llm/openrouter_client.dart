import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';
import 'llm_client.dart';

/// OpenRouter: una chiave sola, molti modelli.
///
/// Utile per confrontare fornitori diversi sui 34 avvisi annotati senza
/// aprire un account per ciascuno. Lo svantaggio rispetto a Gemini diretto
/// e' che la garanzia di output strutturato **dipende dal modello**: qui
/// si chiede `json_object`, che assicura JSON valido ma non che rispetti
/// lo schema. Per questo lo schema finisce anche nel prompt, e la
/// validazione a valle resta indispensabile.
class OpenRouterClient implements LlmClient {
  OpenRouterClient({
    required this.apiKey,
    this.model = 'google/gemini-flash-1.5',
    http.Client? client,
  }) : _client = client ?? http.Client();

  final String apiKey;
  final String model;
  final http.Client _client;

  @override
  String get name => 'openrouter/$model';

  @override
  Future<String> complete(
    String prompt, {
    Map<String, dynamic>? jsonSchema,
  }) async {
    final uri = Uri.parse('https://openrouter.ai/api/v1/chat/completions');

    final body = <String, dynamic>{
      'model': model,
      'temperature': 0,
      'messages': [
        {'role': 'user', 'content': prompt}
      ],
      if (jsonSchema != null)
        'response_format': {'type': 'json_object'},
    };

    final http.Response r;
    try {
      r = await _client
          .post(uri,
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer $apiKey',
                // OpenRouter chiede di identificarsi.
                'X-Title': 'gtt-deviazioni',
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
      final choices = json['choices'] as List?;
      if (choices == null || choices.isEmpty) {
        throw LlmException(name, 'nessuna risposta: ${_snippet(r.body)}');
      }
      final message = (choices.first as Map<String, dynamic>)['message']
          as Map<String, dynamic>?;
      final content = message?['content'] as String?;
      if (content == null) {
        throw LlmException(name, 'risposta senza testo: ${_snippet(r.body)}');
      }
      return content;
    } on LlmException {
      rethrow;
    } on Object catch (e) {
      throw LlmException(name, 'risposta illeggibile: $e');
    }
  }

  static String _snippet(String s) =>
      s.length <= 300 ? s : '${s.substring(0, 300)}...';
}
