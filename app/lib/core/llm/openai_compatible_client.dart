import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';
import 'llm_client.dart';

/// Un client solo per tutti i fornitori che parlano il protocollo OpenAI.
///
/// Sono quasi tutti: OpenRouter, Groq, Mistral, Cerebras, Ollama, LM
/// Studio. Cambiare fornitore e' cambiare `baseUrl` e `model`, quindi si
/// possono confrontare sui 34 avvisi annotati senza riscrivere nulla.
///
/// Nota sulla garanzia di formato: qui si chiede `json_object`, che
/// assicura JSON valido ma **non** che rispetti lo schema — a differenza
/// del `responseSchema` di Gemini. Per questo lo schema finisce anche nel
/// prompt e la validazione a valle resta indispensabile.
class OpenAiCompatibleClient implements LlmClient {
  OpenAiCompatibleClient({
    required this.baseUrl,
    required this.model,
    required this.providerName,
    this.apiKey,
    this.extraHeaders = const {},
    this.timeout = GttConfig.httpTimeout,
    http.Client? client,
  }) : _client = client ?? http.Client();

  /// Ollama in locale: gratuito, nessuna chiave, nessun limite, e i testi
  /// degli avvisi non escono dalla macchina.
  ///
  /// Attenzione: gira dove gira Ollama. Va bene per lo sviluppo, per il
  /// banco di prova e per il processo che sorveglia gli avvisi; NON e'
  /// raggiungibile da un telefono fuori casa.
  factory OpenAiCompatibleClient.ollama({
    String model = 'mistral',
    String host = 'http://localhost:11434',
    http.Client? client,
  }) =>
      OpenAiCompatibleClient(
        baseUrl: '$host/v1/chat/completions',
        model: model,
        providerName: 'ollama',
        // I modelli locali sono piu' lenti: 30 s non bastano.
        timeout: const Duration(minutes: 3),
        client: client,
      );

  /// OpenRouter: una chiave sola per molti modelli, inclusi diversi
  /// gratuiti (suffisso ":free").
  ///
  /// L'elenco dei gratuiti CAMBIA nel tempo: il 31/07/2026 ce n'erano 14,
  /// di cui solo 5 con output strutturato — che per un compito di
  /// estrazione e' il discriminante vero. Verificato che
  /// `google/gemma-3-27b-it:free`, valore predefinito ovvio, non esiste
  /// piu': avrebbe dato 404 in silenzio.
  ///
  /// Per rivedere l'elenco (non serve la chiave):
  ///   curl -s https://openrouter.ai/api/v1/models \
  ///     | jq -r '.data[] | select(.id|endswith(":free"))
  ///              | select(.supported_parameters|index("response_format"))
  ///              | .id'
  factory OpenAiCompatibleClient.openRouter({
    required String apiKey,
    String model = 'google/gemma-4-31b-it:free',
    http.Client? client,
  }) =>
      OpenAiCompatibleClient(
        baseUrl: 'https://openrouter.ai/api/v1/chat/completions',
        model: model,
        providerName: 'openrouter',
        apiKey: apiKey,
        extraHeaders: const {'X-Title': 'gtt-deviazioni'},
        client: client,
      );

  /// Groq: piano gratuito generoso e molto veloce.
  factory OpenAiCompatibleClient.groq({
    required String apiKey,
    String model = 'llama-3.3-70b-versatile',
    http.Client? client,
  }) =>
      OpenAiCompatibleClient(
        baseUrl: 'https://api.groq.com/openai/v1/chat/completions',
        model: model,
        providerName: 'groq',
        apiKey: apiKey,
        client: client,
      );

  final String baseUrl;
  final String model;
  final String providerName;
  final String? apiKey;
  final Map<String, String> extraHeaders;
  final Duration timeout;
  final http.Client _client;

  @override
  String get name => '$providerName/$model';

  @override
  Future<String> complete(
    String prompt, {
    Map<String, dynamic>? jsonSchema,
  }) async {
    final body = <String, dynamic>{
      'model': model,
      'temperature': 0,
      'messages': [
        {'role': 'user', 'content': prompt}
      ],
      if (jsonSchema != null) 'response_format': {'type': 'json_object'},
    };

    final http.Response r;
    try {
      r = await _client
          .post(
            Uri.parse(baseUrl),
            headers: {
              'Content-Type': 'application/json',
              if (apiKey != null) 'Authorization': 'Bearer $apiKey',
              ...extraHeaders,
            },
            body: jsonEncode(body),
          )
          .timeout(timeout);
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
