import 'lyrics_provider.dart';

class LyricsProviderRegistry {
  LyricsProviderRegistry._();
  static final instance = LyricsProviderRegistry._();

  final List<LyricsProvider> _providers = <LyricsProvider>[];

  Iterable<LyricsProvider> get all => List.unmodifiable(_providers);

  Iterable<LyricsProvider> get enabledSorted =>
      _providers.where((p) => p.enabled).toList()
        ..sort((a, b) => a.priority.compareTo(b.priority));

  void register(LyricsProvider p) {
    if (_providers.any((e) => e.id == p.id)) return;
    _providers.add(p);
  }

  void clear() => _providers.clear();
}
