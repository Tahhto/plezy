import 'dart:convert';

import '../../media/media_kind.dart';
import '../../utils/external_ids.dart';
import '../../utils/json_utils.dart';
import 'home_list_ref.dart';

/// Pure response parsers for the custom Home section sources. Kept free of
/// I/O so fixtures can pin each provider's shape.
///
/// Every parser is deliberately lenient: unknown rows are skipped, never
/// fatal, and duplicate titles keep their first (highest-ranked) position.

final RegExp _imdbIdPattern = RegExp(r'^tt\d{5,}$');

String? _imdb(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim().toLowerCase();
  return _imdbIdPattern.hasMatch(trimmed) ? trimmed : null;
}

String? _string(Object? value) => value is String && value.trim().isNotEmpty ? value.trim() : null;

/// Drop later repeats of a title (same kind + any shared id form).
List<HomeListEntry> dedupeHomeListEntries(Iterable<HomeListEntry> entries) {
  final seen = <String>{};
  final result = <HomeListEntry>[];
  for (final entry in entries) {
    final kind = entry.kind?.name ?? '?';
    final keys = [
      if (entry.ids.imdb case final imdb?) 'imdb:$imdb',
      if (entry.ids.tmdb case final tmdb?) 'tmdb:$kind:$tmdb',
      if (entry.ids.tvdb case final tvdb?) 'tvdb:$kind:$tvdb',
    ];
    if (keys.isEmpty || keys.any(seen.contains)) continue;
    seen.addAll(keys);
    result.add(entry);
  }
  return result;
}

// --- Trakt -------------------------------------------------------------------

/// Trakt list/watchlist/catalog rows. Handles every wrapper Trakt uses:
/// list items `{rank, type, movie|show|season|episode}`, trending
/// `{watchers, movie}`, anticipated `{list_count, show}`, box office
/// `{revenue, movie}`, and bare media objects (`/movies/popular`).
/// Season and episode rows resolve to their parent show; people are skipped.
List<HomeListEntry> parseTraktListItems(Object? decoded, {MediaKind? defaultKind}) {
  final entries = <HomeListEntry>[];
  for (final row in flexibleMapList(decoded)) {
    final (media, kind) = switch (row) {
      {'movie': final Map<String, dynamic> m} => (m, MediaKind.movie),
      {'show': final Map<String, dynamic> m} => (m, MediaKind.show),
      {'ids': Map<String, dynamic>()} when defaultKind != null => (row, defaultKind),
      _ => (null, null),
    };
    if (media == null || kind == null) continue;
    final rawIds = media['ids'];
    if (rawIds is! Map) continue;
    final ids = ExternalIds(
      imdb: _imdb(rawIds['imdb']),
      tmdb: flexibleInt(rawIds['tmdb']),
      tvdb: flexibleInt(rawIds['tvdb']),
    );
    if (!ids.hasCatalogIds) continue;
    entries.add(HomeListEntry(kind: kind, ids: ids, title: _string(media['title']), year: flexibleInt(media['year'])));
  }
  return dedupeHomeListEntries(entries);
}

// --- MDBList -----------------------------------------------------------------

/// MDBList list items. Reads both the keyless public export
/// (`/lists/{user}/{slug}/json`: a flat array of
/// `{id, rank, title, imdb_id, tvdb_id, mediatype, release_year}`) and the
/// API's `{movies: [...], shows: [...]}` envelope with nested `ids`.
///
/// The flat export's bare `id` is MDBList's TMDB id. It is only trusted when
/// the row has no IMDb id, so a misread can never override the
/// unambiguous IMDb match.
List<HomeListEntry> parseMdblistItems(Object? decoded) {
  final rows = <(Map<String, dynamic>, MediaKind?)>[];
  if (decoded is Map<String, dynamic>) {
    for (final row in flexibleMapList(decoded['movies'])) {
      rows.add((row, MediaKind.movie));
    }
    for (final row in flexibleMapList(decoded['shows'])) {
      rows.add((row, MediaKind.show));
    }
    // Some exports wrap the flat array as `{items: [...]}`.
    for (final row in flexibleMapList(decoded['items'])) {
      rows.add((row, null));
    }
  } else {
    for (final row in flexibleMapList(decoded)) {
      rows.add((row, null));
    }
  }

  // The API envelope splits movies from shows; `rank` restores the list's
  // interleaved order. `List.sort` is not stable, so ties keep input order
  // through the index.
  final indexed = [for (var i = 0; i < rows.length; i++) (i, rows[i])];
  indexed.sort((a, b) {
    final ra = flexibleInt(a.$2.$1['rank']);
    final rb = flexibleInt(b.$2.$1['rank']);
    final byRank = ra == null || rb == null ? 0 : ra.compareTo(rb);
    return byRank != 0 ? byRank : a.$1.compareTo(b.$1);
  });

  final entries = <HomeListEntry>[];
  for (final (_, (row, envelopeKind)) in indexed) {
    final kind = envelopeKind ?? _mdblistKind(row['mediatype'] ?? row['type']);
    final nested = row['ids'] is Map ? row['ids'] as Map : const <Object?, Object?>{};
    final imdb = _imdb(nested['imdb'] ?? row['imdb_id'] ?? row['imdbid']);
    final explicitTmdb = flexibleInt(nested['tmdb'] ?? row['tmdb_id'] ?? row['tmdbid']);
    final ids = ExternalIds(
      imdb: imdb,
      tmdb: explicitTmdb ?? (imdb == null ? flexibleInt(row['id']) : null),
      tvdb: flexibleInt(nested['tvdb'] ?? row['tvdb_id'] ?? row['tvdbid']),
    );
    if (!ids.hasCatalogIds) continue;
    entries.add(
      HomeListEntry(
        kind: kind,
        ids: ids,
        title: _string(row['title']),
        year: flexibleInt(row['release_year'] ?? row['year']),
      ),
    );
  }
  return dedupeHomeListEntries(entries);
}

MediaKind? _mdblistKind(Object? type) => switch (type) {
  'movie' => MediaKind.movie,
  'show' || 'tv' || 'series' => MediaKind.show,
  _ => null,
};

// --- IMDb --------------------------------------------------------------------

final RegExp _nextDataPattern = RegExp(r'<script[^>]*id="__NEXT_DATA__"[^>]*>(.*?)</script>', dotAll: true);
final RegExp _titleHrefPattern = RegExp(r'/title/(tt\d{5,})/');

/// IMDb list, chart and watchlist pages.
///
/// IMDb has no public list API. Its pages are Next.js apps that embed their
/// data as JSON in `<script id="__NEXT_DATA__">`; rather than hard-code the
/// path to the rows (which IMDb reshuffles), the JSON is walked in document
/// order and every title node — an object whose `id` is a `tt…` id and that
/// carries `titleText` or `titleType` — becomes an entry. Without that
/// script, `/title/tt…/` links are read in page order as a fallback, kind
/// unknown (IMDb ids still match unambiguously).
List<HomeListEntry> parseImdbPage(String html, {MediaKind? defaultKind}) {
  final match = _nextDataPattern.firstMatch(html);
  if (match != null) {
    try {
      final entries = <HomeListEntry>[];
      _collectImdbTitles(jsonDecode(match.group(1)!), entries, defaultKind);
      if (entries.isNotEmpty) return dedupeHomeListEntries(entries);
    } on FormatException {
      // Fall through to the link scan.
    }
  }
  return dedupeHomeListEntries([
    for (final m in _titleHrefPattern.allMatches(html))
      HomeListEntry(
        kind: defaultKind,
        ids: ExternalIds(imdb: m.group(1)),
      ),
  ]);
}

void _collectImdbTitles(Object? node, List<HomeListEntry> out, MediaKind? defaultKind) {
  if (node is List) {
    for (final child in node) {
      _collectImdbTitles(child, out, defaultKind);
    }
    return;
  }
  if (node is! Map) return;
  final imdb = _imdb(node['id']);
  if (imdb != null && (node.containsKey('titleText') || node.containsKey('titleType'))) {
    final titleText = node['titleText'];
    final titleType = node['titleType'];
    final releaseYear = node['releaseYear'];
    out.add(
      HomeListEntry(
        kind: _imdbKind(titleType is Map ? titleType['id'] : null) ?? defaultKind,
        ids: ExternalIds(imdb: imdb),
        title: titleText is Map ? _string(titleText['text']) : null,
        year: releaseYear is Map ? flexibleInt(releaseYear['year']) : null,
      ),
    );
    // A title node's children are its own metadata (and sometimes related
    // titles), not further list rows.
    return;
  }
  for (final value in node.values) {
    _collectImdbTitles(value, out, defaultKind);
  }
}

MediaKind? _imdbKind(Object? titleTypeId) => switch (titleTypeId) {
  'movie' || 'tvMovie' || 'short' || 'video' || 'tvSpecial' => MediaKind.movie,
  'tvSeries' || 'tvMiniSeries' || 'tvShort' => MediaKind.show,
  _ => null,
};
