import '../../media/media_hub.dart';

/// Which titles of a list a custom section keeps.
enum HomeSectionKindFilter { all, movies, shows }

/// A user-defined Home row backed by an external list (Trakt, MDBList, IMDb).
class CustomHomeSection {
  /// Stable id, also the suffix of the section's layout key.
  final String id;
  final String title;

  /// The list URL as the user pasted it; parsed with `HomeListRef.tryParse`.
  final String url;
  final HomeSectionKindFilter kinds;

  /// Cap on the row's length after library matching.
  final int maxItems;

  /// Leave out titles the user has already watched.
  final bool hideWatched;

  static const int defaultMaxItems = 50;

  const CustomHomeSection({
    required this.id,
    required this.title,
    required this.url,
    this.kinds = HomeSectionKindFilter.all,
    this.maxItems = defaultMaxItems,
    this.hideWatched = false,
  });

  String get layoutKey => customSectionLayoutKey(id);

  CustomHomeSection copyWith({
    String? title,
    String? url,
    HomeSectionKindFilter? kinds,
    int? maxItems,
    bool? hideWatched,
  }) => CustomHomeSection(
    id: id,
    title: title ?? this.title,
    url: url ?? this.url,
    kinds: kinds ?? this.kinds,
    maxItems: maxItems ?? this.maxItems,
    hideWatched: hideWatched ?? this.hideWatched,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'url': url,
    'kinds': kinds.name,
    'maxItems': maxItems,
    'hideWatched': hideWatched,
  };

  static CustomHomeSection? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final title = json['title'];
    final url = json['url'];
    if (id is! String || title is! String || url is! String) return null;
    final maxItems = json['maxItems'];
    return CustomHomeSection(
      id: id,
      title: title,
      url: url,
      kinds: HomeSectionKindFilter.values.asNameMap()[json['kinds']] ?? HomeSectionKindFilter.all,
      maxItems: maxItems is int && maxItems > 0 ? maxItems : defaultMaxItems,
      hideWatched: json['hideWatched'] == true,
    );
  }
}

/// The user's Home arrangement: custom sections, the order of every row, and
/// which rows are hidden. Rows are addressed by layout key (see
/// [customSectionLayoutKey] and [builtInHubLayoutKey]).
class HomeLayout {
  final List<CustomHomeSection> sections;

  /// Row order. Keys not listed (a library added later, a section created
  /// before any reordering) fall in after the listed ones; see
  /// [composeHomeHubs].
  final List<String> order;
  final Set<String> hidden;

  const HomeLayout({this.sections = const [], this.order = const [], this.hidden = const {}});

  static const HomeLayout empty = HomeLayout();

  bool get isEmpty => sections.isEmpty && order.isEmpty && hidden.isEmpty;

  HomeLayout copyWith({List<CustomHomeSection>? sections, List<String>? order, Set<String>? hidden}) =>
      HomeLayout(sections: sections ?? this.sections, order: order ?? this.order, hidden: hidden ?? this.hidden);

  Map<String, Object?> toJson() => {
    'sections': [for (final section in sections) section.toJson()],
    'order': order,
    'hidden': hidden.toList(),
  };

  static HomeLayout fromJson(Object? json) {
    if (json is! Map) return empty;
    List<String> strings(Object? value) => value is List ? value.whereType<String>().toList() : const [];
    return HomeLayout(
      sections: [
        if (json['sections'] case final List<dynamic> raw)
          for (final entry in raw) ?CustomHomeSection.fromJson(entry),
      ],
      order: strings(json['order']),
      hidden: strings(json['hidden']).toSet(),
    );
  }
}

String customSectionLayoutKey(String sectionId) => 'custom:$sectionId';

/// Built-in hubs are keyed by server plus the backend's semantic identifier
/// (`library.<id>.recent` on Jellyfin, `movie.recentlyadded` on Plex), which
/// survives refetches; the opaque [MediaHub.id] is the fallback.
String builtInHubLayoutKey(MediaHub hub) => 'hub:${hub.serverId ?? ''}|${hub.identifier ?? hub.id}';

/// Every row key in display order, hidden rows included: saved [HomeLayout.order]
/// first, then any unlisted built-in hub (a library added since), then any
/// unlisted custom section. Keys in the saved order that are not currently
/// present (an offline server's hubs) are skipped, not dropped from the layout.
List<String> homeLayoutRowKeys({
  required List<String> builtInKeys,
  required List<String> customKeys,
  required HomeLayout layout,
}) {
  final present = {...builtInKeys, ...customKeys};
  final placed = <String>{};
  return [
    for (final key in [...layout.order, ...builtInKeys, ...customKeys])
      if (present.contains(key) && placed.add(key)) key,
  ];
}

/// Merge the server's hubs with the resolved custom sections under [layout],
/// in [homeLayoutRowKeys] order with hidden rows dropped. With no saved order,
/// built-in hubs keep their natural order and custom sections follow in
/// creation order. [customHubs] maps section id → hub and holds only sections
/// that resolved to a non-empty row.
List<MediaHub> composeHomeHubs({
  required List<MediaHub> builtInHubs,
  required Map<String, MediaHub> customHubs,
  required HomeLayout layout,
}) {
  final byKey = <String, MediaHub>{};
  for (final hub in builtInHubs) {
    byKey.putIfAbsent(builtInHubLayoutKey(hub), () => hub);
  }
  for (final section in layout.sections) {
    final hub = customHubs[section.id];
    if (hub != null) byKey[section.layoutKey] = hub;
  }
  final rowKeys = homeLayoutRowKeys(
    builtInKeys: [for (final hub in builtInHubs) builtInHubLayoutKey(hub)],
    customKeys: [
      for (final section in layout.sections)
        if (customHubs.containsKey(section.id)) section.layoutKey,
    ],
    layout: layout,
  );
  return [
    for (final key in rowKeys)
      if (!layout.hidden.contains(key)) byKey[key]!,
  ];
}

/// [layout] with [key] moved to [newIndex] among [rowKeys] (the current
/// [homeLayoutRowKeys]). Saved keys not currently present keep their place
/// at the end, so an offline server's rows are not forgotten.
HomeLayout moveHomeLayoutRow(HomeLayout layout, List<String> rowKeys, String key, int newIndex) {
  final keys = [...rowKeys]..remove(key);
  keys.insert(newIndex.clamp(0, keys.length), key);
  final current = keys.toSet();
  return layout.copyWith(
    order: [
      ...keys,
      for (final saved in layout.order)
        if (!current.contains(saved)) saved,
    ],
  );
}
