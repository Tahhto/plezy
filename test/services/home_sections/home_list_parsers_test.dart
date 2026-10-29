import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/home_sections/home_list_parsers.dart';

void main() {
  group('parseTraktListItems', () {
    test('reads list items, resolves seasons/episodes to their show, skips people', () {
      final rows = jsonDecode('''
      [
        {"rank": 1, "type": "movie", "movie": {"title": "The Matrix", "year": 1999,
          "ids": {"trakt": 481, "slug": "the-matrix-1999", "imdb": "tt0133093", "tmdb": 603}}},
        {"rank": 2, "type": "show", "show": {"title": "Breaking Bad", "year": 2008,
          "ids": {"trakt": 1388, "imdb": "tt0903747", "tmdb": 1396, "tvdb": 81189}}},
        {"rank": 3, "type": "episode", "episode": {"season": 1, "number": 1, "ids": {"trakt": 73482}},
          "show": {"title": "Breaking Bad", "year": 2008, "ids": {"imdb": "tt0903747", "tmdb": 1396}}},
        {"rank": 4, "type": "person", "person": {"name": "Keanu Reeves", "ids": {"imdb": "nm0000206"}}},
        {"rank": 5, "type": "movie", "movie": {"title": "No ids", "ids": {"trakt": 1}}}
      ]
      ''');
      final entries = parseTraktListItems(rows);
      expect(entries, hasLength(2), reason: 'episode duplicates the show; person and id-less rows are skipped');
      expect(entries[0].kind, MediaKind.movie);
      expect(entries[0].ids.imdb, 'tt0133093');
      expect(entries[0].ids.tmdb, 603);
      expect(entries[0].title, 'The Matrix');
      expect(entries[1].kind, MediaKind.show);
      expect(entries[1].ids.tvdb, 81189);
    });

    test('reads trending wrappers and bare media with the URL-implied kind', () {
      final trending = jsonDecode('[{"watchers": 50, "movie": {"title": "A", "ids": {"tmdb": 1}}}]');
      expect(parseTraktListItems(trending).single.kind, MediaKind.movie);

      final popular = jsonDecode('[{"title": "B", "year": 2020, "ids": {"imdb": "tt1234567", "tmdb": 2}}]');
      expect(parseTraktListItems(popular), isEmpty, reason: 'bare rows need a kind');
      expect(parseTraktListItems(popular, defaultKind: MediaKind.show).single.kind, MediaKind.show);
    });

    test('tolerates garbage', () {
      expect(parseTraktListItems(null), isEmpty);
      expect(parseTraktListItems({'error': 'x'}), isEmpty);
      expect(parseTraktListItems(jsonDecode('[1, "x", {"movie": "nope"}]')), isEmpty);
    });
  });

  group('parseMdblistItems', () {
    test('reads the flat public export in rank order', () {
      final rows = jsonDecode('''
      [
        {"id": 1396, "rank": 2, "title": "Breaking Bad", "imdb_id": "tt0903747", "tvdb_id": 81189,
          "mediatype": "show", "release_year": 2008},
        {"id": 603, "rank": 1, "title": "The Matrix", "imdb_id": "tt0133093", "tvdb_id": null,
          "mediatype": "movie", "release_year": 1999},
        {"id": 999, "rank": 3, "title": "No IMDb", "imdb_id": null, "mediatype": "movie"}
      ]
      ''');
      final entries = parseMdblistItems(rows);
      expect(entries.map((e) => e.title), ['The Matrix', 'Breaking Bad', 'No IMDb']);
      expect(entries[0].kind, MediaKind.movie);
      expect(entries[0].ids.tmdb, isNull, reason: 'bare id is only trusted without an IMDb id');
      expect(entries[1].ids.tvdb, 81189);
      expect(entries[2].ids.tmdb, 999);
    });

    test('reads the API envelope with nested ids and interleaves by rank', () {
      final body = jsonDecode('''
      {"movies": [{"rank": 2, "title": "M", "ids": {"imdb": "tt0000002", "tmdb": 2}}],
       "shows": [{"rank": 1, "title": "S", "ids": {"imdb": "tt0000001", "tvdb": 1}}]}
      ''');
      final entries = parseMdblistItems(body);
      expect(entries.map((e) => e.title), ['S', 'M']);
      expect(entries[0].kind, MediaKind.show);
      expect(entries[1].kind, MediaKind.movie);
    });

    test('keeps input order for unranked rows', () {
      final rows = jsonDecode('''
      [{"title": "B", "imdb_id": "tt0000002", "mediatype": "movie"},
       {"title": "A", "imdb_id": "tt0000001", "mediatype": "movie"}]
      ''');
      expect(parseMdblistItems(rows).map((e) => e.title), ['B', 'A']);
    });
  });

  group('parseImdbPage', () {
    String page(Object nextData) =>
        '<html><head></head><body><script id="__NEXT_DATA__" type="application/json">'
        '${jsonEncode(nextData)}</script></body></html>';

    test('walks __NEXT_DATA__ for title nodes in document order', () {
      final html = page({
        'props': {
          'pageProps': {
            'mainColumnData': {
              'list': {
                'titleListItemSearch': {
                  'edges': [
                    {
                      'listItem': {
                        'id': 'tt0111161',
                        'titleText': {'text': 'The Shawshank Redemption'},
                        'titleType': {'id': 'movie'},
                        'releaseYear': {'year': 1994},
                        // Nested related titles must not become rows.
                        'moreLikeThis': {
                          'id': 'tt9999999',
                          'titleText': {'text': 'Nope'},
                        },
                      },
                    },
                    {
                      'listItem': {
                        'id': 'tt0903747',
                        'titleText': {'text': 'Breaking Bad'},
                        'titleType': {'id': 'tvSeries'},
                      },
                    },
                    {
                      'listItem': {
                        'id': 'tt0111161',
                        'titleText': {'text': 'Duplicate'},
                      },
                    },
                  ],
                },
              },
            },
          },
        },
      });
      final entries = parseImdbPage(html);
      expect(entries.map((e) => e.ids.imdb), ['tt0111161', 'tt0903747']);
      expect(entries[0].kind, MediaKind.movie);
      expect(entries[0].year, 1994);
      expect(entries[1].kind, MediaKind.show);
    });

    test('unknown title types fall back to the chart kind', () {
      final html = page({
        'x': [
          {
            'id': 'tt0000001',
            'titleType': {'id': 'podcastSeries'},
          },
        ],
      });
      expect(parseImdbPage(html, defaultKind: MediaKind.movie).single.kind, MediaKind.movie);
      expect(parseImdbPage(html).single.kind, isNull);
    });

    test('falls back to title links without __NEXT_DATA__', () {
      const html =
          '<a href="/title/tt0133093/?ref_=x">A</a><a href="/title/tt0133093/">A</a>'
          '<a href="/title/tt0903747/">B</a><a href="/name/nm0000206/">P</a>';
      final entries = parseImdbPage(html);
      expect(entries.map((e) => e.ids.imdb), ['tt0133093', 'tt0903747']);
      expect(entries.first.kind, isNull);
    });

    test('a challenge page yields nothing', () {
      expect(parseImdbPage('<html><body>Please verify you are a human</body></html>'), isEmpty);
    });
  });
}
