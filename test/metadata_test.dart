import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_admin/services/artist_names.dart';
import 'package:playlist_admin/services/metadata_enricher.dart';
import 'package:playlist_admin/services/spotify_gql_client.dart';

/// metadata repair regression tests (pure functions, no file writes).
void main() {
  group('albumYear', () {
    test('ISO date string -> 4 digit year', () {
      expect(SpotifyTrackItem.albumYear({'date': '2011-07-08'}), '2011');
      expect(SpotifyTrackItem.albumYear({'date': '2003'}), '2003');
    });

    test('releaseDate / release_date aliases both read', () {
      expect(SpotifyTrackItem.albumYear({'releaseDate': '1999-12-31'}),
          '1999');
      expect(SpotifyTrackItem.albumYear({'release_date': '1986-01-01'}),
          '1986');
    });

    test('ms timestamp converts; seconds-scale timestamp rejected', () {
      final ms = DateTime.utc(2015, 6, 1).millisecondsSinceEpoch;
      expect(SpotifyTrackItem.albumYear({'date': ms}), '2015');
      expect(SpotifyTrackItem.albumYear({'date': 1433116800}), isNull);
    });

    test('missing / empty / garbage -> null (never 1970)', () {
      expect(SpotifyTrackItem.albumYear(null), isNull);
      expect(SpotifyTrackItem.albumYear({}), isNull);
      expect(SpotifyTrackItem.albumYear({'date': ''}), isNull);
      expect(SpotifyTrackItem.albumYear({'date': 'unknown'}), isNull);
    });
  });

  group('ArtistNames en->zh (artist turned English)', () {
    test('Bestards -> 理想混蛋 (the reported case)', () {
      expect(ArtistNames.toDisplay('Bestards'), '理想混蛋');
    });

    test('other Chinese artists reverse-map to Chinese', () {
      expect(ArtistNames.toDisplay('Claire Kuo'), '郭靜');
      expect(ArtistNames.toDisplay('Crowd Lu'), '盧廣仲');
      expect(ArtistNames.toDisplay('Accusefive'), '告五人');
      expect(ArtistNames.toDisplay('Wu Bai'), '伍佰');
      expect(ArtistNames.toDisplay('Rainie Yang'), '楊丞琳');
      expect(ArtistNames.toDisplay('Khalil Fong'), '方大同');
    });

    test('Japanese/Western artists are left untouched (no guessing)', () {
      expect(ArtistNames.toDisplay('YOASOBI'), 'YOASOBI');
      expect(ArtistNames.toDisplay('Ado'), 'Ado');
      expect(ArtistNames.toDisplay('Taylor Swift'), 'Taylor Swift');
      expect(ArtistNames.toDisplay('Stray Kids'), 'Stray Kids');
      expect(ArtistNames.toDisplay('Aimer'), 'Aimer');
    });

    test('already-Chinese and empty pass through', () {
      expect(ArtistNames.toDisplay('理想混蛋'), '理想混蛋');
      expect(ArtistNames.toDisplay(''), '');
    });

    test('multi-artist list converts each segment, keeps separator', () {
      expect(ArtistNames.toDisplayList('Claire Kuo, Taylor Swift'),
          '郭靜, Taylor Swift');
      expect(ArtistNames.toDisplayList('Crowd Lu，Ado'), '盧廣仲，Ado');
    });

    test('isKnownChineseArtist gates the rewrite', () {
      expect(ArtistNames.isKnownChineseArtist('Bestards'), true);
      expect(ArtistNames.isKnownChineseArtist('理想混蛋'), true);
      expect(ArtistNames.isKnownChineseArtist('YOASOBI'), false);
      expect(ArtistNames.isKnownChineseArtist(''), false);
    });

    test('normalization is case/space insensitive', () {
      expect(ArtistNames.toDisplay('bestards'), '理想混蛋');
      expect(ArtistNames.toDisplay('  BESTARDS  '), '理想混蛋');
      expect(ArtistNames.toDisplay('claire kuo'), '郭靜');
    });
  });

  group('fuzzyKey (album mismatch root cause)', () {
    test('short artist no longer matches long album (BTS->ARIRANG)', () {
      final albumKey = MetadataEnricher.fuzzyKey('ARIRANG');
      final titleKey = MetadataEnricher.fuzzyKey('Body to Body');
      expect(titleKey.contains(albumKey), false);
    });

    test('normalization strips spaces/punctuation; length gate applies', () {
      expect(MetadataEnricher.fuzzyKey('Body to Body'), 'bodytobody');
      expect(MetadataEnricher.fuzzyKey('Like JENNIE'), 'likejennie');
      expect(MetadataEnricher.fuzzyKey('BTS').length < 6, true);
      expect(MetadataEnricher.fuzzyKey('Stray Kids').length >= 6, true);
    });
  });
}