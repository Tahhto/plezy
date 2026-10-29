import 'package:http/http.dart' as http;

import '../trackers/tracker_exceptions.dart';
import '../trackers/tracker_http_client.dart';
import '../trackers/trakt/trakt_client.dart';
import '../trackers/trakt/trakt_constants.dart';
import 'home_list_parsers.dart';
import 'home_list_ref.dart';

/// A list could not be read. [statusCode] is the HTTP status when the
/// provider answered (404: the list does not exist or is private).
class HomeListFetchException implements Exception {
  final HomeListRef ref;
  final int? statusCode;
  final String message;

  const HomeListFetchException(this.ref, this.message, {this.statusCode});

  @override
  String toString() => 'HomeListFetchException($ref, $statusCode: $message)';
}

/// Fetches the titles of a [HomeListRef], in list order.
///
/// Trakt goes through the signed-in user's [TraktClient] when there is one
/// (private lists and `/users/me/…` need it) and otherwise through Trakt's
/// public API with only the app's client id. MDBList public lists use the
/// keyless JSON export. IMDb has no API, so its pages are read as a browser
/// would; see [parseImdbPage].
class HomeListFetcher {
  HomeListFetcher({http.Client? httpClient, TraktClient? Function()? traktClient})
    : _http = TrackerHttpClient(logLabel: 'HomeLists', httpClient: httpClient),
      _traktClient = traktClient ?? _noTrakt;

  final TrackerHttpClient _http;
  final TraktClient? Function() _traktClient;

  static TraktClient? _noTrakt() => null;

  /// Trakt's per-page maximum on list endpoints.
  static const int _traktPageSize = 100;

  static const Map<String, String> _browserHeaders = {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) '
        'Chrome/130.0.0.0 Safari/537.36',
    'Accept': 'text/html,application/xhtml+xml',
    'Accept-Language': 'en-US,en;q=0.9',
  };

  void dispose() => _http.dispose();

  Future<List<HomeListEntry>> fetch(HomeListRef ref, {int maxItems = 100}) => switch (ref.source) {
    HomeListSource.trakt => _fetchTrakt(ref, maxItems),
    HomeListSource.mdblist => _fetchMdblist(ref, maxItems),
    HomeListSource.imdb => _fetchImdb(ref, maxItems),
  };

  Future<List<HomeListEntry>> _fetchTrakt(HomeListRef ref, int maxItems) async {
    // List and watchlist endpoints take a type filter; catalog feeds do not.
    final isListEndpoint = ref.path.endsWith('/items') || ref.path.endsWith('/watchlist');
    final basePath = isListEndpoint ? '${ref.path}/movie,show' : ref.path;
    final entries = <HomeListEntry>[];
    for (var page = 1; entries.length < maxItems; page++) {
      final response = await _traktGet('$basePath?page=$page&limit=$_traktPageSize', ref);
      final rows = TrackerHttpClient.decodeJson(response.body);
      final pageEntries = parseTraktListItems(rows, defaultKind: ref.defaultKind);
      entries.addAll(pageEntries);
      final pageCount = int.tryParse(response.headers['x-pagination-page-count'] ?? '');
      final rowCount = rows is List ? rows.length : 0;
      if (rowCount < _traktPageSize || pageCount == null || page >= pageCount) break;
    }
    return dedupeHomeListEntries(entries).take(maxItems).toList(growable: false);
  }

  Future<http.Response> _traktGet(String pathAndQuery, HomeListRef ref) async {
    final client = _traktClient();
    if (client != null) {
      try {
        return await client.getRaw(pathAndQuery);
      } catch (error) {
        throw HomeListFetchException(ref, '$error', statusCode: _statusOf(error));
      }
    }
    final response = await _http.send(
      'GET',
      Uri.parse('${TraktConstants.apiBase}$pathAndQuery'),
      headers: TraktConstants.headers(),
    );
    if (response.statusCode != 200) {
      throw HomeListFetchException(ref, 'Trakt answered ${response.statusCode}', statusCode: response.statusCode);
    }
    return response;
  }

  static int? _statusOf(Object error) => switch (error) {
    TrackerApiException(:final statusCode) => statusCode,
    TrackerAuthException(:final statusCode) => statusCode,
    _ => null,
  };

  Future<List<HomeListEntry>> _fetchMdblist(HomeListRef ref, int maxItems) async {
    final response = await _http.send('GET', Uri.parse('https://mdblist.com/lists/${ref.path}/json'));
    if (response.statusCode != 200) {
      throw HomeListFetchException(ref, 'MDBList answered ${response.statusCode}', statusCode: response.statusCode);
    }
    return parseMdblistItems(TrackerHttpClient.decodeJson(response.body)).take(maxItems).toList(growable: false);
  }

  Future<List<HomeListEntry>> _fetchImdb(HomeListRef ref, int maxItems) async {
    final response = await _http.send('GET', Uri.parse('https://www.imdb.com${ref.path}'), headers: _browserHeaders);
    if (response.statusCode != 200) {
      throw HomeListFetchException(ref, 'IMDb answered ${response.statusCode}', statusCode: response.statusCode);
    }
    final entries = parseImdbPage(response.body, defaultKind: ref.defaultKind);
    if (entries.isEmpty) {
      // A 200 with no titles is IMDb's bot challenge page, not an empty list.
      throw HomeListFetchException(ref, 'IMDb returned no titles (blocked or empty page)', statusCode: 200);
    }
    return entries.take(maxItems).toList(growable: false);
  }
}
