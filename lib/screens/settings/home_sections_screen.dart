import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../media/media_hub.dart';
import '../../models/home_sections/home_layout.dart';
import '../../providers/discover_provider.dart';
import '../../providers/home_sections_provider.dart';
import '../../services/home_sections/home_list_fetcher.dart';
import '../../services/home_sections/home_list_ref.dart';
import '../../utils/dialogs.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focusable_list_tile.dart';
import '../../widgets/setting_tile.dart';
import '../../widgets/settings_page.dart';
import '../../widgets/settings_section.dart';

/// Settings → Appearance → Home Sections: add rows backed by Trakt, MDBList
/// or IMDb lists, and reorder or hide every Home row (built-in ones too).
///
/// Every row action goes through a picker dialog rather than inline buttons
/// or drag handles, so the screen works the same with touch, mouse and a TV
/// remote.
class HomeSectionsScreen extends StatelessWidget {
  const HomeSectionsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final sections = context.watch<HomeSectionsProvider>();
    final builtInHubs = context.watch<DiscoverProvider>().hubs;
    final layout = sections.layout;
    final theme = Theme.of(context);

    final builtInByKey = <String, MediaHub>{};
    for (final hub in builtInHubs) {
      builtInByKey.putIfAbsent(builtInHubLayoutKey(hub), () => hub);
    }
    final customByKey = {for (final section in layout.sections) section.layoutKey: section};
    final rowKeys = homeLayoutRowKeys(
      builtInKeys: builtInByKey.keys.toList(),
      customKeys: customByKey.keys.toList(),
      layout: layout,
    );
    final showServerNames = {for (final hub in builtInHubs) hub.serverId}.length > 1;

    Widget rowTile(int index, String key) {
      final hidden = layout.hidden.contains(key);
      final custom = customByKey[key];
      final hub = builtInByKey[key];
      final String title;
      final String subtitle;
      final IconData icon;
      if (custom != null) {
        title = custom.title;
        final error = sections.errors[custom.id];
        final resolved = sections.customHubs[custom.id];
        subtitle = [
          t.homeSections.customSource(source: _sourceName(HomeListRef.tryParse(custom.url)?.source)),
          if (error != null)
            t.homeSections.failed(error: error)
          else if (resolved == null && !sections.isLoading)
            t.homeSections.noMatches,
          if (hidden) t.homeSections.hidden,
        ].join(' · ');
        icon = Symbols.playlist_play_rounded;
      } else {
        title = hub!.title;
        subtitle = [
          if (showServerNames && hub.serverName != null) hub.serverName!,
          if (hidden) t.homeSections.hidden,
        ].join(' · ');
        icon = Symbols.view_carousel_rounded;
      }
      return FocusableListTile(
        key: ValueKey('home-row-$key'),
        leading: AppIcon(hidden ? Symbols.visibility_off_rounded : icon, fill: 1),
        title: Text(title, style: hidden ? TextStyle(color: theme.colorScheme.onSurfaceVariant) : null),
        subtitle: subtitle.isEmpty ? null : Text(subtitle),
        trailing: const AppIcon(Symbols.more_vert_rounded, fill: 1),
        onTap: () => _rowActions(context, rowKeys, index, key, custom),
      );
    }

    return SettingsPage(
      title: Text(t.homeSections.title),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Text(
            t.homeSections.intro,
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
        SettingsGroup(
          children: [
            SettingNavigationTile(
              icon: Symbols.playlist_add_rounded,
              title: t.homeSections.addSection,
              trailingIcon: Symbols.add_rounded,
              onTap: () => _addSection(context),
            ),
            if (layout.order.isNotEmpty || layout.hidden.isNotEmpty)
              SettingNavigationTile(
                icon: Symbols.restart_alt_rounded,
                title: t.homeSections.resetLayout,
                trailingIcon: Symbols.undo_rounded,
                onTap: () => sections.saveLayout(layout.copyWith(order: const [], hidden: const {})),
              ),
          ],
        ),
        SettingsGroup(
          title: t.homeSections.rows,
          children: [
            if (rowKeys.isEmpty) ListTile(title: Text(t.homeSections.noRows)),
            for (var i = 0; i < rowKeys.length; i++) rowTile(i, rowKeys[i]),
          ],
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  static String _sourceName(HomeListSource? source) => switch (source) {
    HomeListSource.trakt => 'Trakt',
    HomeListSource.mdblist => 'MDBList',
    HomeListSource.imdb => 'IMDb',
    null => '?',
  };

  /// A readable default title from the URL: the list slug title-cased, or the
  /// chart's name.
  static String suggestedTitle(HomeListRef ref) {
    const charts = {
      '/chart/top/': 'IMDb Top 250 Movies',
      '/chart/toptv/': 'IMDb Top 250 TV Shows',
      '/chart/moviemeter/': 'Most Popular Movies',
      '/chart/tvmeter/': 'Most Popular TV Shows',
      '/chart/boxoffice/': 'Box Office',
      '/chart/bottom/': 'IMDb Bottom 100',
    };
    if (charts[ref.path] case final chart?) return chart;
    final segments = ref.path.split('/').where((s) => s.isNotEmpty && s != 'items').toList();
    if (segments.isEmpty) return _sourceName(ref.source);
    var slug = segments.last;
    if (slug == 'watchlist') return 'Watchlist';
    if (ref.source == HomeListSource.trakt &&
        segments.length == 2 &&
        (segments[0] == 'movies' || segments[0] == 'shows')) {
      slug = '${segments[1]} ${segments[0]}';
    } else if (ref.source == HomeListSource.trakt && segments.length == 3) {
      slug = '${segments[1]} ${segments[0]}';
    }
    return slug
        .split(RegExp(r'[-_\s]+'))
        .where((w) => w.isNotEmpty)
        .map((w) => w[0].toUpperCase() + w.substring(1))
        .join(' ');
  }

  Future<void> _addSection(BuildContext context) async {
    final provider = context.read<HomeSectionsProvider>();
    final url = await _askUrl(context);
    if (url == null || !context.mounted) return;
    final ref = HomeListRef.tryParse(url)!;
    final title = await showTextInputDialog(
      context,
      title: t.homeSections.sectionTitle,
      labelText: t.homeSections.sectionTitle,
      initialValue: suggestedTitle(ref),
      confirmText: t.common.save,
    );
    if (title == null || title.trim().isEmpty || !context.mounted) return;
    final kinds = await _askKinds(context);
    if (kinds == null || !context.mounted) return;

    final section = CustomHomeSection(
      id: DateTime.now().microsecondsSinceEpoch.toRadixString(36),
      title: title.trim(),
      url: url.trim(),
      kinds: kinds,
    );
    final layout = provider.layout;
    await provider.saveLayout(
      layout.copyWith(
        sections: [...layout.sections, section],
        // A saved order lists every row; keep the new one last in it.
        order: layout.order.isEmpty ? null : [...layout.order, section.layoutKey],
      ),
    );
    if (context.mounted) await _test(context, section.url, kinds);
  }

  Future<String?> _askUrl(BuildContext context, {String? initialValue}) => showTextInputDialog(
    context,
    title: t.homeSections.listUrl,
    labelText: t.homeSections.listUrl,
    hintText: t.homeSections.listUrlHint,
    initialValue: initialValue,
    keyboardType: TextInputType.url,
    inputFormatters: [FilteringTextInputFormatter.deny(RegExp(r'\s'))],
    validator: (value) => HomeListRef.tryParse(value) == null ? t.homeSections.unsupportedUrl : null,
  );

  Future<HomeSectionKindFilter?> _askKinds(BuildContext context) => showOptionPickerDialog<HomeSectionKindFilter>(
    context,
    title: t.homeSections.show,
    options: [
      (icon: Symbols.video_library_rounded, label: t.homeSections.showAll, value: HomeSectionKindFilter.all),
      (icon: Symbols.movie_rounded, label: t.homeSections.showMovies, value: HomeSectionKindFilter.movies),
      (icon: Symbols.tv_rounded, label: t.homeSections.showShows, value: HomeSectionKindFilter.shows),
    ],
  );

  Future<void> _test(BuildContext context, String url, HomeSectionKindFilter kinds) async {
    final provider = context.read<HomeSectionsProvider>();
    try {
      final result = await provider.preview(url, kinds: kinds);
      if (!context.mounted) return;
      showAppSnackBar(
        context,
        t.homeSections.testResult(listed: result.listed.toString(), owned: result.owned.toString()),
      );
    } catch (error) {
      if (!context.mounted) return;
      showErrorSnackBar(
        context,
        t.homeSections.failed(error: error is HomeListFetchException ? error.message : '$error'),
      );
    }
  }

  Future<void> _rowActions(
    BuildContext context,
    List<String> rowKeys,
    int index,
    String key,
    CustomHomeSection? custom,
  ) async {
    final provider = context.read<HomeSectionsProvider>();
    final layout = provider.layout;
    final hidden = layout.hidden.contains(key);
    final action = await showOptionPickerDialog<_RowAction>(
      context,
      title: custom?.title ?? t.homeSections.rows,
      options: [
        if (index > 0)
          (icon: Symbols.vertical_align_top_rounded, label: t.homeSections.moveToTop, value: _RowAction.top),
        if (index > 0) (icon: Symbols.arrow_upward_rounded, label: t.homeSections.moveUp, value: _RowAction.up),
        if (index < rowKeys.length - 1)
          (icon: Symbols.arrow_downward_rounded, label: t.homeSections.moveDown, value: _RowAction.down),
        (
          icon: hidden ? Symbols.visibility_rounded : Symbols.visibility_off_rounded,
          label: hidden ? t.homeSections.unhide : t.homeSections.hide,
          value: _RowAction.toggleHidden,
        ),
        if (custom != null) ...[
          (icon: Symbols.edit_rounded, label: t.homeSections.rename, value: _RowAction.rename),
          (icon: Symbols.link_rounded, label: t.homeSections.changeUrl, value: _RowAction.changeUrl),
          (icon: Symbols.filter_list_rounded, label: t.homeSections.show, value: _RowAction.kinds),
          (icon: Symbols.format_list_numbered_rounded, label: t.homeSections.maxItems, value: _RowAction.maxItems),
          (
            icon: custom.hideWatched ? Symbols.visibility_rounded : Symbols.visibility_off_rounded,
            label: custom.hideWatched ? t.homeSections.showWatched : t.homeSections.hideWatched,
            value: _RowAction.toggleWatched,
          ),
          (icon: Symbols.science_rounded, label: t.homeSections.test, value: _RowAction.test),
          (icon: Symbols.delete_rounded, label: t.homeSections.delete, value: _RowAction.delete),
        ],
      ],
    );
    if (action == null || !context.mounted) return;

    Future<void> updateSection(CustomHomeSection updated) => provider.saveLayout(
      layout.copyWith(sections: [for (final s in layout.sections) s.id == updated.id ? updated : s]),
    );

    switch (action) {
      case _RowAction.top:
        await provider.saveLayout(moveHomeLayoutRow(layout, rowKeys, key, 0));
      case _RowAction.up:
        await provider.saveLayout(moveHomeLayoutRow(layout, rowKeys, key, index - 1));
      case _RowAction.down:
        await provider.saveLayout(moveHomeLayoutRow(layout, rowKeys, key, index + 1));
      case _RowAction.toggleHidden:
        await provider.saveLayout(
          layout.copyWith(hidden: hidden ? ({...layout.hidden}..remove(key)) : {...layout.hidden, key}),
        );
      case _RowAction.rename:
        final title = await showTextInputDialog(
          context,
          title: t.homeSections.rename,
          labelText: t.homeSections.sectionTitle,
          initialValue: custom!.title,
          confirmText: t.common.save,
        );
        if (title != null && title.trim().isNotEmpty) await updateSection(custom.copyWith(title: title.trim()));
      case _RowAction.changeUrl:
        final url = await _askUrl(context, initialValue: custom!.url);
        if (url != null) await updateSection(custom.copyWith(url: url.trim()));
      case _RowAction.kinds:
        final kinds = await _askKinds(context);
        if (kinds != null) await updateSection(custom!.copyWith(kinds: kinds));
      case _RowAction.maxItems:
        final value = await showTextInputDialog(
          context,
          title: t.homeSections.maxItems,
          labelText: t.homeSections.maxItems,
          initialValue: custom!.maxItems.toString(),
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          validator: (v) => (int.tryParse(v) ?? 0) > 0 ? null : t.homeSections.maxItems,
          confirmText: t.common.save,
        );
        final parsed = value == null ? null : int.tryParse(value);
        if (parsed != null && parsed > 0) await updateSection(custom.copyWith(maxItems: parsed));
      case _RowAction.toggleWatched:
        await updateSection(custom!.copyWith(hideWatched: !custom.hideWatched));
      case _RowAction.test:
        await _test(context, custom!.url, custom.kinds);
      case _RowAction.delete:
        final confirmed = await showConfirmDialog(
          context,
          title: t.homeSections.delete,
          message: t.homeSections.deleteConfirm(title: custom!.title),
          confirmText: t.common.delete,
          isDestructive: true,
        );
        if (!confirmed) return;
        await provider.saveLayout(
          layout.copyWith(
            sections: [
              for (final s in layout.sections)
                if (s.id != custom.id) s,
            ],
            order: [
              for (final k in layout.order)
                if (k != key) k,
            ],
            hidden: {...layout.hidden}..remove(key),
          ),
        );
    }
  }
}

enum _RowAction { top, up, down, toggleHidden, rename, changeUrl, kinds, maxItems, toggleWatched, test, delete }
