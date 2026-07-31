import 'dart:convert';

import '../llm/llm_client.dart';
import '../models/notice.dart';

/// Cosa dice un avviso, in forma strutturata.
enum DeviationType {
  deviazione,
  limitazione,
  inversione,
  sostituzioneModale,
  sospensioneFermate,
  altro;

  static DeviationType parse(String? s) => switch (s) {
        'deviazione' => deviazione,
        'limitazione' => limitazione,
        'inversione' => inversione,
        'sostituzione_modale' => sostituzioneModale,
        'sospensione_fermate' => sospensioneFermate,
        _ => altro,
      };
}

class ParsedDeviation {
  const ParsedDeviation({
    required this.type,
    this.lines = const [],
    this.directionDesc,
    this.municipality,
    this.detachStreet,
    this.detachCrossStreet,
    this.viaSequence = const [],
    this.rejoinStreet,
    this.suspendedStopCodes = const [],
    this.temporaryTerminusStreet,
    this.temporaryTerminusStopCode,
    this.ambiguities = const [],
  });

  final DeviationType type;
  final List<String> lines;
  final String? directionDesc;

  /// Dal testo, quando GTT lo dichiara ("Nel Comune di Chieri"). E' il
  /// vincolo che disambigua le decine di "via Roma" dell'area (§10.7).
  final String? municipality;

  final String? detachStreet;
  final String? detachCrossStreet;

  /// Le vie percorse dalla deviazione, IN ORDINE. L'ordine conta: e'
  /// quello che diventa la sequenza di waypoint per il routing.
  final List<String> viaSequence;

  final String? rejoinStreet;
  final List<String> suspendedStopCodes;
  final String? temporaryTerminusStreet;
  final String? temporaryTerminusStopCode;

  /// Cosa il modello non e' riuscito a interpretare. Va conservato e
  /// mostrato: e' meglio dire "non ho capito questo pezzo" che inventarlo.
  final List<String> ambiguities;

  /// Tutti i toponimi da geocodificare, in ordine di percorrenza.
  List<String> get allToponyms => [
        ?detachStreet,
        ...viaSequence,
        ?rejoinStreet,
      ];

  static ParsedDeviation fromJson(Map<String, dynamic> j) {
    List<String> strings(Object? v) => (v as List?)
            ?.map((e) => e is String ? e : (e as Map)['street']?.toString())
            .whereType<String>()
            .toList() ??
        const [];

    Map<String, dynamic>? obj(Object? v) =>
        v is Map<String, dynamic> ? v : null;

    final detach = obj(j['detach_point']);
    final rejoin = obj(j['rejoin_point']);
    final terminus = obj(j['temporary_terminus']);

    return ParsedDeviation(
      type: DeviationType.parse(j['deviation_type'] as String?),
      lines: strings(j['lines']),
      directionDesc: j['direction_desc'] as String?,
      municipality: j['municipality'] as String?,
      detachStreet: detach?['street'] as String?,
      detachCrossStreet: detach?['cross_street'] as String?,
      viaSequence: strings(j['via_sequence']),
      rejoinStreet: rejoin?['street'] as String?,
      suspendedStopCodes: strings(j['suspended_stop_codes']),
      temporaryTerminusStreet: terminus?['street'] as String?,
      temporaryTerminusStopCode: terminus?['stop_code'] as String?,
      ambiguities: strings(j['ambiguities']),
    );
  }

  @override
  String toString() => '${type.name} '
      '${directionDesc != null ? "[$directionDesc] " : ""}'
      'da ${detachStreet ?? "?"} '
      'via ${viaSequence.join(" > ")}'
      '${rejoinStreet != null ? " rientro a $rejoinStreet" : ""}';
}

enum ExtractionStatus { ok, parseFailed, error }

class ExtractionResult {
  const ExtractionResult({
    required this.status,
    this.deviations = const [],
    this.detail,
    this.attempts = 1,
    this.retryAfter,
  });

  final ExtractionStatus status;
  final List<ParsedDeviation> deviations;
  final String? detail;
  final int attempts;

  /// Quando riprovare, se il fornitore l'ha detto.
  final DateTime? retryAfter;

  bool get isUsable => status == ExtractionStatus.ok && deviations.isNotEmpty;

  @override
  String toString() => switch (status) {
        ExtractionStatus.ok => '${deviations.length} deviazioni estratte'
            '${attempts > 1 ? " (al tentativo $attempts)" : ""}',
        ExtractionStatus.parseFailed => 'ESTRAZIONE FALLITA: $detail',
        ExtractionStatus.error => 'ERRORE: $detail',
      };
}

/// Da prosa burocratica italiana a JSON strutturato.
///
/// **L'errore da non ripetere** (§5.2.1): chiedere al modello di produrre
/// il percorso. Non puo': non conosce la geometria di Torino con
/// precisione metrica e allucinerebbe coordinate plausibili ma sbagliate.
/// Qui il modello fa una cosa sola, e la fa bene: legge il testo e ne
/// riporta i pezzi. Zero geografia, zero coordinate, zero inferenza
/// spaziale — quelle le fanno il geocoder e il router, che sanno dov'e'
/// via Cigna.
class NoticeExtractor {
  const NoticeExtractor({required this.llm});

  final LlmClient llm;

  /// Schema della risposta. I fornitori che lo supportano nativamente lo
  /// applicano; per gli altri finisce comunque nel prompt.
  static const responseSchema = <String, dynamic>{
    'type': 'object',
    'properties': {
      'deviations': {
        'type': 'array',
        'items': {
          'type': 'object',
          'properties': {
            'lines': {
              'type': 'array',
              'items': {'type': 'string'}
            },
            'direction_desc': {'type': 'string', 'nullable': true},
            'deviation_type': {
              'type': 'string',
              'enum': [
                'deviazione',
                'limitazione',
                'inversione',
                'sostituzione_modale',
                'sospensione_fermate',
                'altro'
              ],
            },
            'municipality': {'type': 'string', 'nullable': true},
            'detach_point': {
              'type': 'object',
              'nullable': true,
              'properties': {
                'street': {'type': 'string', 'nullable': true},
                'cross_street': {'type': 'string', 'nullable': true},
              },
            },
            'via_sequence': {
              'type': 'array',
              'items': {
                'type': 'object',
                'properties': {
                  'street': {'type': 'string'}
                },
              },
            },
            'rejoin_point': {
              'type': 'object',
              'nullable': true,
              'properties': {
                'street': {'type': 'string', 'nullable': true},
                'phrase': {'type': 'string', 'nullable': true},
              },
            },
            'suspended_stop_codes': {
              'type': 'array',
              'items': {'type': 'string'}
            },
            'temporary_terminus': {
              'type': 'object',
              'nullable': true,
              'properties': {
                'street': {'type': 'string', 'nullable': true},
                'stop_code': {'type': 'string', 'nullable': true},
              },
            },
            'ambiguities': {
              'type': 'array',
              'items': {'type': 'string'}
            },
          },
          'required': ['deviation_type', 'via_sequence'],
        },
      },
    },
    'required': ['deviations'],
  };

  static String buildPrompt(RawNotice notice) => '''
Sei un estrattore di dati. Ricevi il testo di un avviso GTT (Torino) su una
variazione di percorso. Restituisci SOLO JSON valido, nessun commento.

REGOLE ASSOLUTE
- Non inventare vie non presenti nel testo.
- Non produrre coordinate: non e' il tuo compito e sbaglieresti.
- Trascrivi i toponimi ESATTAMENTE come scritti, compresi "corso", "via",
  "piazza", "strada", "lungo Dora", "largo", "ponte".
- Se il testo descrive piu' direzioni, produci un oggetto per direzione.
- Se il testo contiene sia una sostituzione di mezzo sia una limitazione,
  produci un oggetto per ciascuna.
- Se un campo non e' ricavabile dal testo, usa null. Mai un valore
  plausibile.
- Attenzione: le vie citate come CAUSA dei lavori non sono il percorso.
  "Causa lavori in via Rossini" non significa che il mezzo passi di li'.
- "percorso attuale" non e' "percorso normale": il primo implica che c'e'
  gia' un'altra deviazione attiva.
- Metti in "ambiguities" i pezzi di testo che non sei riuscito a
  interpretare, invece di indovinare.

TIPI
- deviazione: il mezzo passa altrove e poi rientra
- limitazione: la linea si accorcia, un tratto NON e' servito
- inversione: inversione di marcia
- sostituzione_modale: stesso percorso, mezzo diverso (bus al posto del tram)
- sospensione_fermate: una o piu' fermate sospese, percorso invariato
- altro

SCHEMA
{
  "deviations": [{
    "lines": ["55"],
    "direction_desc": "direzione corso Farini" | null,
    "deviation_type": "deviazione",
    "municipality": "Torino" | null,
    "detach_point": {"street": "via Pininfarina", "cross_street": null},
    "via_sequence": [{"street": "via Ferrero"}, {"street": "via Di Vittorio"}],
    "rejoin_point": {"street": null, "phrase": "percorso normale"},
    "suspended_stop_codes": ["9009"],
    "temporary_terminus": {"street": "...", "stop_code": "1182"} | null,
    "ambiguities": []
  }]
}

TESTO:
${notice.fullText}
''';

  /// Estrae, valida, e se la validazione fallisce riprova UNA volta.
  /// Poi si arrende e lo dichiara: meglio mostrare all'utente il testo
  /// originale che una struttura inventata (§5.2.1).
  Future<ExtractionResult> extract(RawNotice notice) async {
    final prompt = buildPrompt(notice);

    for (var attempt = 1; attempt <= 2; attempt++) {
      final String raw;
      try {
        raw = await llm.complete(prompt, jsonSchema: responseSchema);
      } on LlmException catch (e) {
        return ExtractionResult(
          status: ExtractionStatus.error,
          detail: '$e',
          attempts: attempt,
          retryAfter: e.retryAfter,
        );
      }

      final parsed = _tryParse(raw);
      if (parsed != null) {
        return ExtractionResult(
            status: ExtractionStatus.ok,
            deviations: parsed,
            attempts: attempt);
      }
    }

    return const ExtractionResult(
      status: ExtractionStatus.parseFailed,
      detail: 'risposta non conforme allo schema dopo due tentativi',
      attempts: 2,
    );
  }

  /// null se la risposta non e' utilizzabile.
  static List<ParsedDeviation>? _tryParse(String raw) {
    // Alcuni modelli incorniciano il JSON in un blocco markdown.
    var text = raw.trim();
    if (text.startsWith('```')) {
      text = text.replaceFirst(RegExp(r'^```(?:json)?\s*'), '');
      final end = text.lastIndexOf('```');
      if (end >= 0) text = text.substring(0, end);
      text = text.trim();
    }

    try {
      final json = jsonDecode(text);
      if (json is! Map<String, dynamic>) return null;
      final list = json['deviations'];
      if (list is! List) return null;
      final out = <ParsedDeviation>[];
      for (final item in list) {
        if (item is Map<String, dynamic>) {
          out.add(ParsedDeviation.fromJson(item));
        }
      }
      return out.isEmpty ? null : out;
    } on Object {
      return null;
    }
  }
}
