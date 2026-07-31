import 'package:shared_preferences/shared_preferences.dart';

/// Le poche cose che l'app deve ricordare.
///
/// La chiave dell'LLM sta qui, cioe' sul dispositivo. Per un'app personale
/// va bene; significa pero' non pubblicarla cosi' com'e', e mettere un
/// tetto di spesa sul fornitore.
class Settings {
  Settings(this._prefs);

  static const _kWatchlist = 'watchlist';
  static const _kApiKey = 'openrouter_key';
  static const _kModel = 'llm_model';

  final SharedPreferences _prefs;

  static Future<Settings> load() async =>
      Settings(await SharedPreferences.getInstance());

  /// Le linee che interessano, coi nomi che usa la gente ("55", "STAR 1").
  /// Poche: il sistema lavora per linea, non sulla rete intera.
  List<String> get watchlist => _prefs.getStringList(_kWatchlist) ?? const [];

  Future<void> setWatchlist(List<String> lines) =>
      _prefs.setStringList(_kWatchlist, lines);

  Future<void> addLine(String line) async {
    final l = line.trim();
    if (l.isEmpty) return;
    final current = watchlist.toList();
    if (current.any((x) => x.toUpperCase() == l.toUpperCase())) return;
    current.add(l);
    await setWatchlist(current);
  }

  Future<void> removeLine(String line) async {
    await setWatchlist(
        watchlist.where((x) => x != line).toList(growable: false));
  }

  String? get apiKey {
    final k = _prefs.getString(_kApiKey);
    return (k == null || k.isEmpty) ? null : k;
  }

  Future<void> setApiKey(String key) => _prefs.setString(_kApiKey, key.trim());

  bool get hasApiKey => apiKey != null;

  /// La chiave ha la forma giusta?
  ///
  /// Una chiave incollata male o alterata da una sostituzione tipografica
  /// ("sk'or'v1'...") produce un 401 identico a quello di una chiave
  /// sbagliata. Meglio accorgersene qui che a Torino sotto la pensilina.
  static bool looksLikeOpenRouterKey(String key) =>
      RegExp(r'^sk-or-v1-[A-Za-z0-9]{16,}$').hasMatch(key.trim());

  bool get apiKeyLooksValid {
    final k = apiKey;
    return k != null && looksLikeOpenRouterKey(k);
  }

  /// Scelto per misura sui 34 avvisi annotati: 34 su 34 estratti, nessun
  /// toponimo inventato.
  String get model =>
      _prefs.getString(_kModel) ?? 'nvidia/nemotron-3-super-120b-a12b:free';

  Future<void> setModel(String m) => _prefs.setString(_kModel, m);
}
