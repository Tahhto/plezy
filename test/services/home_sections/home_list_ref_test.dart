import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/home_sections/home_list_ref.dart';

void main() {
  HomeListRef? parse(String url) => HomeListRef.tryParse(url);

  group('Trakt', () {
    test('user list, with and without scheme/www/app host and query', () {
      const expected = HomeListRef(HomeListSource.trakt, '/users/sean/lists/star-wars-in-order/items');
      expect(parse('https://trakt.tv/users/sean/lists/star-wars-in-order'), expected);
      expect(parse('trakt.tv/users/sean/lists/star-wars-in-order/'), expected);
      expect(parse('https://app.trakt.tv/users/sean/lists/star-wars-in-order?sort=rank,asc'), expected);
      expect(parse('  https://www.trakt.tv/users/sean/lists/star-wars-in-order  '), expected);
    });

    test('watchlist and lists by id', () {
      expect(
        parse('https://trakt.tv/users/sean/watchlist'),
        const HomeListRef(HomeListSource.trakt, '/users/sean/watchlist'),
      );
      expect(parse('https://trakt.tv/lists/12345'), const HomeListRef(HomeListSource.trakt, '/lists/12345/items'));
    });

    test('catalog feeds carry their kind; period feeds default to weekly', () {
      expect(
        parse('https://trakt.tv/movies/trending'),
        const HomeListRef(HomeListSource.trakt, '/movies/trending', defaultKind: MediaKind.movie),
      );
      expect(
        parse('https://trakt.tv/shows/watched'),
        const HomeListRef(HomeListSource.trakt, '/shows/watched/weekly', defaultKind: MediaKind.show),
      );
      expect(
        parse('https://trakt.tv/shows/watched/monthly'),
        const HomeListRef(HomeListSource.trakt, '/shows/watched/monthly', defaultKind: MediaKind.show),
      );
    });

    test('non-list pages are rejected', () {
      expect(parse('https://trakt.tv/movies/the-matrix-1999'), isNull);
      expect(parse('https://trakt.tv/users/sean'), isNull);
    });
  });

  group('MDBList', () {
    test('public list', () {
      expect(
        parse('https://mdblist.com/lists/linaspurinis/top-watched-movies-of-the-week'),
        const HomeListRef(HomeListSource.mdblist, 'linaspurinis/top-watched-movies-of-the-week'),
      );
    });

    test('non-list pages are rejected', () {
      expect(parse('https://mdblist.com/movie/tt0133093'), isNull);
    });
  });

  group('IMDb', () {
    test('user lists', () {
      const expected = HomeListRef(HomeListSource.imdb, '/list/ls055592025/');
      expect(parse('https://www.imdb.com/list/ls055592025/'), expected);
      expect(parse('https://m.imdb.com/list/ls055592025/?ref_=nv'), expected);
    });

    test('charts carry their kind', () {
      expect(
        parse('https://www.imdb.com/chart/top/'),
        const HomeListRef(HomeListSource.imdb, '/chart/top/', defaultKind: MediaKind.movie),
      );
      expect(
        parse('imdb.com/chart/tvmeter'),
        const HomeListRef(HomeListSource.imdb, '/chart/tvmeter/', defaultKind: MediaKind.show),
      );
    });

    test('public watchlists', () {
      expect(
        parse('https://www.imdb.com/user/ur12345678/watchlist'),
        const HomeListRef(HomeListSource.imdb, '/user/ur12345678/watchlist/'),
      );
    });

    test('title pages and malformed ids are rejected', () {
      expect(parse('https://www.imdb.com/title/tt0133093/'), isNull);
      expect(parse('https://www.imdb.com/list/notalist/'), isNull);
    });
  });

  test('unknown hosts and junk are rejected', () {
    expect(parse(''), isNull);
    expect(parse('not a url'), isNull);
    expect(parse('https://letterboxd.com/user/list/x/'), isNull);
  });
}
