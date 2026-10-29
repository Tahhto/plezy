import '../../media/media_kind.dart';
import '../../utils/external_ids.dart';

/// Where a custom Home section's titles come from.
enum HomeListSource { trakt, mdblist, imdb }

/// A parsed list URL: which service, and the request that lists its titles.
///
/// [path] is source-specific: a Trakt API path without the type suffix
/// (`/users/sean/lists/favorites/items`), an MDBList `user/slug` pair, or an
/// IMDb page path (`/list/ls055592025/`, `/chart/top/`). [defaultKind] is the
/// kind implied by the URL itself (Trakt `/movies/trending`), for endpoints
/// whose rows do not say.
class HomeListRef {
  final HomeListSource source;
  final String path;
  final MediaKind? defaultKind;

  const HomeListRef(this.source, this.path, {this.defaultKind});

  @override
  bool operator ==(Object other) =>
      other is HomeListRef && other.source == source && other.path == path && other.defaultKind == defaultKind;

  @override
  int get hashCode => Object.hash(source, path, defaultKind);

  @override
  String toString() => 'HomeListRef(${source.name}, $path)';

  /// Parse a URL the user pasted. Accepts scheme-less input
  /// (`trakt.tv/users/…`), `www.`/`m.`/`app.` hosts, query strings and
  /// trailing slashes. Returns null for anything that is not a supported list.
  static HomeListRef? tryParse(String input) {
    var text = input.trim();
    if (text.isEmpty) return null;
    if (!text.contains('://')) text = 'https://$text';
    final uri = Uri.tryParse(text);
    if (uri == null || uri.host.isEmpty) return null;
    final host = uri.host.toLowerCase().replaceFirst(RegExp(r'^(www|m|app)\.'), '');
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    return switch (host) {
      'trakt.tv' => _parseTrakt(segments),
      'mdblist.com' => _parseMdblist(segments),
      'imdb.com' => _parseImdb(segments),
      _ => null,
    };
  }

  static const Set<String> _traktCatalogFeeds = {
    'trending',
    'popular',
    'anticipated',
    'boxoffice',
    'favorited',
    'watched',
    'played',
    'collected',
  };

  static HomeListRef? _parseTrakt(List<String> s) {
    // /users/{user}/lists/{slug}
    if (s.length >= 4 && s[0] == 'users' && s[2] == 'lists') {
      return HomeListRef(HomeListSource.trakt, '/users/${s[1]}/lists/${s[3]}/items');
    }
    // /users/{user}/watchlist
    if (s.length >= 3 && s[0] == 'users' && s[2] == 'watchlist') {
      return HomeListRef(HomeListSource.trakt, '/users/${s[1]}/watchlist');
    }
    // /lists/{id} (official and public lists by id)
    if (s.length >= 2 && s[0] == 'lists') {
      return HomeListRef(HomeListSource.trakt, '/lists/${s[1]}/items');
    }
    // /movies/trending, /shows/popular, …
    if (s.length >= 2 && (s[0] == 'movies' || s[0] == 'shows') && _traktCatalogFeeds.contains(s[1])) {
      // `watched`/`played`/`collected` take a period; Trakt's site defaults to weekly.
      final period = const {'watched', 'played', 'collected'}.contains(s[1])
          ? '/${s.length >= 3 ? s[2] : 'weekly'}'
          : '';
      return HomeListRef(
        HomeListSource.trakt,
        '/${s[0]}/${s[1]}$period',
        defaultKind: s[0] == 'movies' ? MediaKind.movie : MediaKind.show,
      );
    }
    return null;
  }

  static HomeListRef? _parseMdblist(List<String> s) {
    // /lists/{user}/{slug}
    if (s.length >= 3 && s[0] == 'lists') {
      return HomeListRef(HomeListSource.mdblist, '${s[1]}/${s[2]}');
    }
    return null;
  }

  static final RegExp _imdbListId = RegExp(r'^ls\d+$');
  static final RegExp _imdbUserId = RegExp(r'^ur\d+$');
  static const Map<String, MediaKind> _imdbCharts = {
    'top': MediaKind.movie,
    'moviemeter': MediaKind.movie,
    'boxoffice': MediaKind.movie,
    'bottom': MediaKind.movie,
    'toptv': MediaKind.show,
    'tvmeter': MediaKind.show,
  };

  static HomeListRef? _parseImdb(List<String> s) {
    if (s.length >= 2 && s[0] == 'list' && _imdbListId.hasMatch(s[1])) {
      return HomeListRef(HomeListSource.imdb, '/list/${s[1]}/');
    }
    if (s.length >= 2 && s[0] == 'chart' && _imdbCharts.containsKey(s[1])) {
      return HomeListRef(HomeListSource.imdb, '/chart/${s[1]}/', defaultKind: _imdbCharts[s[1]]);
    }
    if (s.length >= 3 && s[0] == 'user' && _imdbUserId.hasMatch(s[1]) && s[2] == 'watchlist') {
      return HomeListRef(HomeListSource.imdb, '/user/${s[1]}/watchlist/');
    }
    return null;
  }
}

/// One title of a fetched list, in list order.
class HomeListEntry {
  /// Movie or show; null when the source does not say (IMDb rows of an
  /// unrecognised title type), in which case only the IMDb id can match.
  final MediaKind? kind;
  final ExternalIds ids;
  final String? title;
  final int? year;

  const HomeListEntry({required this.ids, this.kind, this.title, this.year});

  @override
  String toString() => 'HomeListEntry(${kind?.name}, ${ids.imdb ?? ids.tmdb ?? ids.tvdb}, $title)';
}
