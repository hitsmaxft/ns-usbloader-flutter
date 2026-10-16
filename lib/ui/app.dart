// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../core/files.dart';
import '../core/library.dart';
import '../services/catalog.dart';
import '../services/downloads.dart';
import 'controller.dart';

const ink = Color(0xffeef2ff),
    muted = Color(0xff8c98b5),
    accent = Color(0xffb8f77b),
    panel = Color(0xff151d30);
String bytesLabel(int n) {
  if (n >= 1024 * 1024 * 1024) {
    return '${(n / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
  if (n >= 1024 * 1024) return '${(n / (1024 * 1024)).toStringAsFixed(1)} MB';
  return '$n B';
}

class LoaderApp extends StatelessWidget {
  final AppController controller;
  const LoaderApp({super.key, required this.controller});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'NS-USBloader',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      brightness: Brightness.dark,
      useMaterial3: true,
      scaffoldBackgroundColor: const Color(0xff0b1020),
      colorScheme: ColorScheme.fromSeed(
        seedColor: accent,
        brightness: Brightness.dark,
        surface: panel,
        primary: accent,
      ),
      fontFamily: 'Arial',
      dialogTheme: const DialogThemeData(backgroundColor: panel),
      dividerColor: const Color(0xff273047),
      textTheme: const TextTheme(
        headlineLarge: TextStyle(
          fontSize: 32,
          fontWeight: FontWeight.w700,
          letterSpacing: -1,
          color: ink,
        ),
        titleLarge: TextStyle(
          fontSize: 21,
          fontWeight: FontWeight.w600,
          color: ink,
        ),
        bodyMedium: TextStyle(color: ink),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: panel,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
      ),
      cardTheme: CardThemeData(
        color: panel,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
    ),
    home: LoaderHome(controller: controller),
  );
}

class LoaderHome extends StatefulWidget {
  final AppController controller;
  const LoaderHome({super.key, required this.controller});
  @override
  State<LoaderHome> createState() => _LoaderHomeState();
}

class _LoaderHomeState extends State<LoaderHome> {
  AppController get c => widget.controller;
  int page = 0;
  String query = '';
  String filter = 'All games';
  PayloadProject project = PayloadProject.hekate;
  List<PayloadRelease> releases = [];
  PayloadRelease? release;
  List<(PayloadRelease, File)> cached = [];
  String? payloadPath;
  bool payloadBusy = false, toolsBusy = false;
  Cancellation? payloadCancel, toolsCancel;
  String payloadStatus = '', toolsStatus = '';
  @override
  void initState() {
    super.initState();
    unawaited(_loadCached());
  }

  Future<void> _loadCached() async {
    final value = await c.payloads.cached();
    if (mounted) setState(() => cached = value);
  }

  @override
  void dispose() {
    payloadCancel?.cancel();
    toolsCancel?.cancel();
    super.dispose();
  }

  Future<void> action(Future<void> Function() task) async {
    try {
      await task();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> addFolder() async {
    final path = await getDirectoryPath();
    if (path != null) await c.addFolder(path);
  }

  Future<void> addFiles() async {
    final files = await openFiles(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'Nintendo packages',
          extensions: ['nsp', 'xci', 'nsz', 'xcz'],
        ),
      ],
    );
    if (files.isNotEmpty) await c.addFiles(files.map((file) => file.path));
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: c,
    builder: (context, _) {
      final narrow = MediaQuery.sizeOf(context).width < 720;
      final content = Padding(
        padding: EdgeInsets.all(narrow ? 18 : 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (c.error != null)
              MaterialBanner(
                content: Text(c.error!),
                actions: [
                  TextButton(
                    onPressed: () {
                      c.error = null;
                      c.changed();
                    },
                    child: const Text('Dismiss'),
                  ),
                ],
              ),
            Expanded(
              child: switch (page) {
                0 => library(),
                1 => queue(),
                2 => rcm(),
                _ => tools(),
              },
            ),
          ],
        ),
      );
      return Scaffold(
        body: SafeArea(
          child: Row(
            children: [
              if (!narrow) navigation(),
              Expanded(child: content),
            ],
          ),
        ),
        bottomNavigationBar: narrow
            ? NavigationBar(
                selectedIndex: page,
                onDestinationSelected: (v) => setState(() => page = v),
                destinations: const [
                  NavigationDestination(
                    icon: Icon(Icons.grid_view_rounded),
                    label: 'Library',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.swap_vert_rounded),
                    label: 'Queue',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.bolt_rounded),
                    label: 'RCM',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.tune_rounded),
                    label: 'Tools',
                  ),
                ],
              )
            : null,
      );
    },
  );
  Widget navigation() {
    final wide = MediaQuery.sizeOf(context).width > 1150;
    return Container(
      width: wide ? 208 : 88,
      decoration: const BoxDecoration(
        border: Border(right: BorderSide(color: Color(0xff202a41))),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 34),
            child: wide
                ? const FittedBox(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.all_inclusive, color: accent, size: 30),
                        SizedBox(width: 10),
                        Text(
                          'NS / LOADER',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1,
                          ),
                        ),
                      ],
                    ),
                  )
                : const Icon(Icons.all_inclusive, color: accent, size: 30),
          ),
          Expanded(
            child: NavigationRail(
              extended: wide,
              backgroundColor: Colors.transparent,
              selectedIndex: page,
              onDestinationSelected: (v) => setState(() => page = v),
              labelType: wide ? null : NavigationRailLabelType.all,
              destinations: const [
                NavigationRailDestination(
                  icon: Icon(Icons.grid_view_rounded),
                  label: Text('Library'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.swap_vert_rounded),
                  label: Text('Queue'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.bolt_rounded),
                  label: Text('RCM boot'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.tune_rounded),
                  label: Text('Tools'),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(20),
            child: Text(
              wide ? 'YOUR COLLECTION.\nREADY TO GO.' : '0.1',
              style: const TextStyle(
                color: muted,
                fontSize: 11,
                height: 1.8,
                letterSpacing: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget title(String eyebrow, String title, List<Widget> actions) => Padding(
    padding: const EdgeInsets.only(bottom: 24),
    child: Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 28,
      runSpacing: 16,
      children: [
        SizedBox(
          width: 280,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                eyebrow,
                style: const TextStyle(
                  color: accent,
                  fontSize: 11,
                  letterSpacing: 2,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(title, style: Theme.of(context).textTheme.headlineLarge),
            ],
          ),
        ),
        Wrap(spacing: 8, runSpacing: 8, children: actions),
      ],
    ),
  );
  Widget library() {
    final groups = c.groups.where((g) {
      final name = c.catalog.forGroup(g)?.name ?? g.representative.label;
      final matches = '$name ${g.id} ${g.representative.source.name}'
          .toLowerCase()
          .contains(query.toLowerCase());
      return matches &&
          (filter == 'All games' ||
              (filter == 'With updates' && g.count(ContentKind.update) > 0) ||
              (filter == 'With DLC' && g.count(ContentKind.dlc) > 0) ||
              (filter == 'Orphans' && g.orphan));
    }).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        title('COLLECTION', 'Your library', [
          IconButton(
            tooltip: 'Folders & metadata',
            onPressed: () => action(librarySettings),
            icon: const Icon(Icons.settings_outlined),
          ),
          IconButton(
            tooltip: c.scanning ? 'Cancel scan' : 'Rescan',
            onPressed: c.scanning
                ? () => c.scanCancel?.cancel()
                : () => action(c.scan),
            icon: Icon(c.scanning ? Icons.close : Icons.refresh),
          ),
          FilledButton.icon(
            onPressed: () => action(addFolder),
            icon: const Icon(Icons.add),
            label: const Text('Add folder'),
          ),
          OutlinedButton.icon(
            onPressed: () => action(addFiles),
            icon: const Icon(Icons.note_add_outlined),
            label: const Text('Add files'),
          ),
        ]),
        Text(
          '${c.groups.length} games   /   ${c.packages.length} packages',
          style: const TextStyle(color: muted),
        ),
        const SizedBox(height: 20),
        TextField(
          onChanged: (value) => setState(() => query = value),
          decoration: const InputDecoration(
            hintText: 'Search your collection',
            prefixIcon: Icon(Icons.search),
          ),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final value in [
              'All games',
              'With updates',
              'With DLC',
              'Orphans',
            ])
              ChoiceChip(
                label: Text(value),
                selected: filter == value,
                onSelected: (_) => setState(() => filter = value),
              ),
          ],
        ),
        const SizedBox(height: 18),
        if (c.scanning) const LinearProgressIndicator(),
        if (c.scanIssues.isNotEmpty)
          TextButton.icon(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => AlertDialog(
                title: const Text('Skipped items'),
                content: SizedBox(
                  width: 600,
                  child: SingleChildScrollView(
                    child: SelectableText(c.scanIssues.join('\n\n')),
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Close'),
                  ),
                ],
              ),
            ),
            icon: const Icon(Icons.info_outline, size: 16),
            label: Text('${c.scanIssues.length} scan issues'),
          ),
        Expanded(
          child: groups.isEmpty
              ? empty(
                  Icons.auto_awesome_mosaic_outlined,
                  c.packages.isEmpty
                      ? 'A home for your collection'
                      : 'No matching games',
                  c.packages.isEmpty
                      ? 'Add a folder or package files.'
                      : 'Try a different name or filter.',
                )
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final columns = max(
                      1,
                      (constraints.maxWidth / 218).floor(),
                    );
                    return GridView.builder(
                      itemCount: groups.length,
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        crossAxisSpacing: 20,
                        mainAxisSpacing: 22,
                        mainAxisExtent: 300,
                      ),
                      itemBuilder: (_, i) => gameCard(groups[i], i),
                    );
                  },
                ),
        ),
        if (c.selected.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(top: 16),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            decoration: BoxDecoration(
              color: panel,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: accent.withValues(alpha: .4)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${c.selected.length} selected · ${bytesLabel(c.selection.fold(0, (s, e) => s + e.source.length))}',
                  ),
                ),
                TextButton(
                  onPressed: () {
                    c.selected.clear();
                    c.changed();
                  },
                  child: const Text('Clear'),
                ),
                FilledButton(
                  onPressed: () => setState(() => page = 1),
                  child: const Text('Open queue'),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget gameCard(GameGroup group, int index) {
    final meta = c.catalog.forGroup(group);
    final name = meta?.name ?? group.representative.label;
    return InkWell(
      onTap: () => details(group),
      borderRadius: BorderRadius.circular(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  cover(group, meta, index),
                  Positioned(
                    top: 12,
                    left: 12,
                    child: pill(
                      group.orphan
                          ? 'UNLINKED CONTENT'
                          : group.representative.format,
                    ),
                  ),
                  if (group.packages.any((p) => c.selected.contains(p.key)))
                    const Positioned(
                      top: 12,
                      right: 12,
                      child: CircleAvatar(
                        radius: 13,
                        backgroundColor: accent,
                        child: Icon(Icons.check, size: 17, color: Colors.black),
                      ),
                    ),
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    child: Container(
                      height: 65,
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Colors.transparent, Color(0xcc060b17)],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
          ),
          const SizedBox(height: 5),
          Text(
            meta?.publisher.isNotEmpty == true
                ? meta!.publisher
                : group.representative.evidence == IdentityEvidence.unknown
                ? 'Identify title'
                : '${group.representative.evidence.name} ID',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: muted, fontSize: 12),
          ),
          const SizedBox(height: 7),
          Text(
            '${group.count(ContentKind.base)} base  ·  ${group.count(ContentKind.update)} updates  ·  ${group.count(ContentKind.dlc)} DLC',
            style: const TextStyle(color: accent, fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget cover(GameGroup group, TitleMetadata? meta, int index) {
    final fallback = CustomPaint(
      painter: CoverPainter(group.id.hashCode),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            (meta?.name ?? group.representative.label).toUpperCase(),
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontWeight: FontWeight.w900,
              fontSize: 25,
              letterSpacing: 2,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
    if (meta?.icon == null) return fallback;
    return FutureBuilder<File?>(
      future: c.catalogStore.cover(meta!.icon),
      builder: (_, snapshot) => snapshot.data == null
          ? fallback
          : Image.file(
              snapshot.data!,
              fit: BoxFit.cover,
              errorBuilder: (_, e, s) => fallback,
            ),
    );
  }

  Widget pill(String label) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
    decoration: BoxDecoration(
      color: const Color(0xdd10172a),
      borderRadius: BorderRadius.circular(7),
    ),
    child: Text(
      label,
      style: const TextStyle(
        fontSize: 9,
        fontWeight: FontWeight.w800,
        letterSpacing: 1,
      ),
    ),
  );
  Widget empty(IconData icon, String heading, String text) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 50, color: accent),
        const SizedBox(height: 20),
        Text(heading, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(
          text,
          style: const TextStyle(color: muted),
          textAlign: TextAlign.center,
        ),
      ],
    ),
  );
  Future<void> details(GameGroup group) async {
    var kind = group.count(ContentKind.base) > 0
        ? ContentKind.base
        : group.representative.kind;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, localSet) => AnimatedBuilder(
          animation: c,
          builder: (_, _) {
            final current =
                c.groups.where((g) => g.id == group.id).firstOrNull ?? group;
            final items = current.packages
                .where((p) => p.kind == kind)
                .toList();
            return Dialog(
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: 780,
                  maxHeight: 650,
                ),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              c.catalog.forGroup(current)?.name ??
                                  current.representative.label,
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                          ),
                          IconButton(
                            onPressed: () => Navigator.pop(dialogContext),
                            icon: const Icon(Icons.close),
                          ),
                        ],
                      ),
                      Text(
                        current.id.startsWith('file:')
                            ? 'Identity not assigned'
                            : current.id,
                        style: const TextStyle(color: muted),
                      ),
                      const SizedBox(height: 20),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final type in ContentKind.values)
                            if (type != ContentKind.unknown ||
                                current.count(type) > 0)
                              ChoiceChip(
                                label: Text(
                                  '${type == ContentKind.dlc ? 'DLC' : type.name[0].toUpperCase() + type.name.substring(1)} (${current.count(type)})',
                                ),
                                selected: type == kind,
                                onSelected: (_) => localSet(() => kind = type),
                              ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: items.isEmpty
                            ? empty(
                                Icons.inventory_2_outlined,
                                'No ${kind.name} packages',
                                'Other content remains available above.',
                              )
                            : ListView(
                                children: [
                                  for (final item in items)
                                    Card(
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 8,
                                        ),
                                        child: Row(
                                          children: [
                                            Checkbox(
                                              value: c.selected.contains(
                                                item.key,
                                              ),
                                              onChanged: (v) =>
                                                  c.toggle(item, v!),
                                            ),
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Text(
                                                    item.source.name,
                                                    style: const TextStyle(
                                                      fontWeight:
                                                          FontWeight.w600,
                                                    ),
                                                  ),
                                                  const SizedBox(height: 6),
                                                  Text(
                                                    '${item.format} · ${item.version == '—' ? 'Version unknown' : 'v${item.version}'} · ${bytesLabel(item.source.length)} · ${item.evidence.name} ID',
                                                    style: const TextStyle(
                                                      color: muted,
                                                      fontSize: 12,
                                                    ),
                                                  ),
                                                  Text(
                                                    item.source.path,
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: const TextStyle(
                                                      color: muted,
                                                      fontSize: 11,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                            IconButton(
                                              tooltip: 'Identify or regroup',
                                              onPressed: () =>
                                                  action(() => identify(item)),
                                              icon: const Icon(
                                                Icons.edit_outlined,
                                                size: 18,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: () {
                              for (final item in items) {
                                c.toggle(item, true);
                              }
                            },
                            child: const Text('Select this group'),
                          ),
                          const SizedBox(width: 12),
                          FilledButton(
                            onPressed: () {
                              Navigator.pop(dialogContext);
                              setState(() => page = 1);
                            },
                            child: const Text('Review queue'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> identify(Package item) async {
    final id = TextEditingController(text: item.titleId ?? '');
    final group = TextEditingController(text: item.groupOverride ?? '');
    final search = TextEditingController(text: item.label);
    var kind = item.kind;
    String? validation;
    var candidates = c.catalog.suggestions(item.label);
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) => AlertDialog(
          title: const Text('Identify content'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: search,
                    decoration: const InputDecoration(
                      labelText: 'Search Title DB',
                    ),
                    onChanged: (value) =>
                        update(() => candidates = c.catalog.suggestions(value)),
                  ),
                  if (candidates.isNotEmpty)
                    SizedBox(
                      height: 160,
                      child: ListView(
                        children: [
                          for (final candidate in candidates)
                            ListTile(
                              dense: true,
                              title: Text(candidate.name),
                              subtitle: Text(candidate.id),
                              onTap: () => update(() {
                                id.text = candidate.id;
                                kind = classifyId(candidate.id).$2;
                              }),
                            ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: id,
                    decoration: const InputDecoration(
                      labelText: 'Title ID (16 hex digits)',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: group,
                    decoration: const InputDecoration(
                      labelText: 'Base game ID override (optional)',
                    ),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<ContentKind>(
                    key: ValueKey(kind),
                    initialValue: kind,
                    items: [
                      for (final type in ContentKind.values)
                        DropdownMenuItem(value: type, child: Text(type.name)),
                    ],
                    onChanged: (v) => kind = v!,
                    decoration: const InputDecoration(
                      labelText: 'Content type',
                    ),
                  ),
                  if (validation != null)
                    Text(
                      validation!,
                      style: const TextStyle(color: Colors.redAccent),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                unawaited(action(() => c.setIdentity(item, null)));
              },
              child: const Text('Reset'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if ((id.text.isNotEmpty && normalizeId(id.text) == null) ||
                    (group.text.isNotEmpty &&
                        normalizeId(group.text) == null)) {
                  update(
                    () => validation = 'Use a complete 16-digit title ID.',
                  );
                  return;
                }
                final value = {
                  'titleId': normalizeId(id.text),
                  'groupId': normalizeId(group.text),
                  'kind': kind.name,
                };
                Navigator.pop(ctx);
                unawaited(action(() => c.setIdentity(item, value)));
              },
              child: const Text('Apply'),
            ),
          ],
        ),
      ),
    );
    id.dispose();
    group.dispose();
    search.dispose();
  }

  Future<void> librarySettings() async {
    var region = c.preferences.region;
    var fallback = c.preferences.englishFallback;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AnimatedBuilder(
        animation: c,
        builder: (_, _) => StatefulBuilder(
          builder: (ctx, update) => AlertDialog(
            title: const Text('Library settings'),
            content: SizedBox(
              width: 550,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final source in c.library.sources)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(source.path),
                        subtitle: Text(
                          '${source.kind.name} · ${source.published ? 'Published' : 'Private'}${source.available ? '' : ' · unavailable'}',
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Switch(
                              value: source.published,
                              onChanged: (value) =>
                                  c.setSourcePublished(source.id, value),
                            ),
                            IconButton(
                              tooltip: 'Remove from library',
                              onPressed: () =>
                                  action(() => c.removeSource(source.id)),
                              icon: const Icon(Icons.remove_circle_outline),
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<String>(
                      initialValue: region,
                      decoration: const InputDecoration(
                        labelText: 'Title DB language',
                      ),
                      items: [
                        for (final value in CatalogStore.regions)
                          DropdownMenuItem(value: value, child: Text(value)),
                      ],
                      onChanged: c.refreshingCatalog
                          ? null
                          : (value) => update(() => region = value!),
                    ),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Include English fallback'),
                      value: fallback,
                      onChanged: c.refreshingCatalog
                          ? null
                          : (value) => update(() => fallback = value!),
                    ),
                    const Text(
                      'Title DB · blawar · MIT\nMetadata may download up to 160 MB per language.',
                      style: TextStyle(color: muted, fontSize: 12),
                    ),
                    if (c.refreshingCatalog)
                      const Padding(
                        padding: EdgeInsets.only(top: 12),
                        child: LinearProgressIndicator(),
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Close'),
              ),
              FilledButton(
                onPressed: c.refreshingCatalog
                    ? () => c.catalogCancel?.cancel()
                    : () => action(
                        () => c.refreshCatalog(region, fallback: fallback),
                      ),
                child: Text(
                  c.refreshingCatalog ? 'Cancel download' : 'Refresh metadata',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget queue() => ListView(
    children: [
      title('TRANSFER', 'Ready when you are', []),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${c.selection.length} selected packages',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              const Text(
                'Awoo-compatible installer',
                style: TextStyle(color: muted),
              ),
              const SizedBox(height: 20),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  FilledButton.icon(
                    onPressed: c.selection.isEmpty
                        ? null
                        : () => action(networkDialog),
                    icon: const Icon(Icons.wifi),
                    label: const Text('Send over network'),
                  ),
                  OutlinedButton.icon(
                    onPressed:
                        c.selection.isEmpty ||
                            c.usbBusy ||
                            c.device == null ||
                            c.device!.rcm
                        ? null
                        : () => action(() => c.startUsb()),
                    icon: const Icon(Icons.usb),
                    label: const Text('Send over USB'),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              deviceSelector(rcm: false),
              for (final entry in c.selection)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(
                    Icons.insert_drive_file_outlined,
                    size: 18,
                  ),
                  title: Text(
                    entry.source.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Text(
                    bytesLabel(entry.source.length),
                    style: const TextStyle(color: muted),
                  ),
                ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 24),
      Text('Activity', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 12),
      if (c.jobs.isEmpty)
        const Padding(
          padding: EdgeInsets.all(24),
          child: Text('Transfers appear here.', style: TextStyle(color: muted)),
        ),
      for (final job in c.jobs)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        job.title,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    if (job.active)
                      TextButton(
                        onPressed: job.cancel.cancel,
                        child: const Text('Cancel'),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(job.status, style: const TextStyle(color: muted)),
                if (job.active || job.total > 0) ...[
                  const SizedBox(height: 14),
                  LinearProgressIndicator(value: job.progress),
                  const SizedBox(height: 8),
                  Text(
                    '${bytesLabel(job.done)} / ${bytesLabel(job.total)}',
                    style: const TextStyle(color: muted, fontSize: 12),
                  ),
                ],
              ],
            ),
          ),
        ),
    ],
  );
  Widget deviceSelector({required bool rcm}) => Row(
    children: [
      Expanded(
        child: DropdownButtonFormField<String>(
          key: ValueKey('${c.device?.key}:$rcm:${c.devices.length}'),
          initialValue: c.device?.rcm == rcm ? c.device?.key : null,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: rcm ? 'RCM device' : 'Installer device',
          ),
          items: [
            for (final device in c.devices.where((d) => d.rcm == rcm))
              DropdownMenuItem(
                value: device.key,
                child: Text(device.label, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: c.usbBusy
              ? null
              : (key) => c.chooseDevice(
                  c.devices.where((d) => d.key == key).firstOrNull,
                ),
        ),
      ),
      const SizedBox(width: 8),
      IconButton(
        tooltip: 'Refresh USB devices',
        onPressed: c.usbBusy ? null : () => action(c.refreshDevices),
        icon: const Icon(Icons.refresh),
      ),
    ],
  );
  Future<void> networkDialog() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    );
    if (!mounted) return;
    final console = TextEditingController();
    final host = TextEditingController(
      text: interfaces.expand((i) => i.addresses).firstOrNull?.address ?? '',
    );
    final port = TextEditingController(text: '0');
    String? error;
    final value = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) => AlertDialog(
          title: const Text('Network transfer'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: console,
                  decoration: const InputDecoration(labelText: 'Console IP'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: host,
                  decoration: const InputDecoration(
                    labelText: 'This computer’s LAN IP',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: port,
                  decoration: const InputDecoration(
                    labelText: 'HTTP port (0 = automatic)',
                  ),
                ),
                if (error != null)
                  Text(error!, style: const TextStyle(color: Colors.redAccent)),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final number = int.tryParse(port.text);
                if (InternetAddress.tryParse(console.text) == null ||
                    InternetAddress.tryParse(host.text) == null ||
                    number == null ||
                    number < 0 ||
                    number > 65535) {
                  update(() => error = 'Enter valid IP addresses and port.');
                  return;
                }
                Navigator.pop(ctx, true);
              },
              child: const Text('Start transfer'),
            ),
          ],
        ),
      ),
    );
    if (value == true) {
      await c.startNetwork(console.text, host.text, port: int.parse(port.text));
    }
    console.dispose();
    host.dispose();
    port.dispose();
  }

  Widget rcm() => ListView(
    children: [
      title('BOOT TOOLS', 'RCM payloads', []),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.cloud_download_outlined, color: accent),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Official releases',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 20,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 22),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final value in PayloadProject.values)
                    ChoiceChip(
                      label: Text(
                        value == PayloadProject.hekate
                            ? 'Hekate'
                            : 'Atmosphère fusee',
                      ),
                      selected: project == value,
                      onSelected: payloadBusy
                          ? null
                          : (_) => setState(() {
                              project = value;
                              releases = [];
                              release = null;
                            }),
                    ),
                  OutlinedButton(
                    onPressed: payloadBusy ? null : () => action(fetchReleases),
                    child: const Text('Find versions'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                project == PayloadProject.fusee
                    ? 'Choose the version matching your installed Atmosphère.'
                    : 'Injection payload only. Nyx SD resources are separate.',
                style: const TextStyle(color: muted, fontSize: 12),
              ),
              const SizedBox(height: 18),
              if (releases.isNotEmpty)
                DropdownButtonFormField<PayloadRelease>(
                  key: ValueKey(releases),
                  initialValue: release,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Release version',
                  ),
                  items: [
                    for (final item in releases)
                      DropdownMenuItem(
                        value: item,
                        child: Text(
                          '${item.tag} · ${item.name}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: payloadBusy
                      ? null
                      : (v) => setState(() => release = v),
                ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  FilledButton.icon(
                    onPressed: payloadBusy || release == null
                        ? null
                        : () => action(downloadPayload),
                    icon: const Icon(Icons.download),
                    label: const Text('Download & cache'),
                  ),
                  if (payloadBusy)
                    TextButton(
                      onPressed: () => payloadCancel?.cancel(),
                      child: const Text('Cancel'),
                    ),
                ],
              ),
              if (payloadBusy)
                const Padding(
                  padding: EdgeInsets.only(top: 16),
                  child: LinearProgressIndicator(),
                ),
              if (payloadStatus.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    payloadStatus,
                    style: const TextStyle(color: muted),
                  ),
                ),
              for (final item in cached)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('${item.$1.project.name} · ${item.$1.tag}'),
                  subtitle: Text(
                    item.$1.digest == null
                        ? 'Cached · no published checksum'
                        : 'Cached · published SHA-256 checked',
                  ),
                  trailing: TextButton(
                    onPressed: payloadBusy
                        ? null
                        : () => action(() async {
                            final file = await c.payloads.download(item.$1);
                            setState(() => payloadPath = file.path);
                          }),
                    child: const Text('Use'),
                  ),
                ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 20),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Inject payload',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              const Text(
                'Unpatched, vulnerable RCM hardware only.',
                style: TextStyle(color: muted, fontSize: 12),
              ),
              const SizedBox(height: 20),
              deviceSelector(rcm: true),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      payloadPath == null
                          ? 'Choose a cached or local payload'
                          : p.basename(payloadPath!),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () => action(() async {
                      final file = await openFile(
                        acceptedTypeGroups: [
                          const XTypeGroup(
                            label: 'Payload',
                            extensions: ['bin'],
                          ),
                        ],
                      );
                      if (file != null) setState(() => payloadPath = file.path);
                    }),
                    icon: const Icon(Icons.folder_open),
                    label: const Text('Browse'),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed:
                    payloadPath == null || c.device?.rcm != true || c.usbBusy
                    ? null
                    : () => action(() async {
                        setState(() => page = 1);
                        await c.startUsb(payload: payloadPath);
                      }),
                icon: const Icon(Icons.bolt),
                label: const Text('Inject selected payload'),
              ),
            ],
          ),
        ),
      ),
    ],
  );
  Future<void> fetchReleases() async {
    setState(() {
      payloadBusy = true;
      payloadStatus = '';
      payloadCancel = Cancellation();
    });
    try {
      final items = await c.payloads.releases(project, cancel: payloadCancel);
      if (mounted) {
        setState(() {
          releases = items;
          release = items.firstOrNull;
          payloadStatus =
              c.payloads.releaseWarning ??
              (items.isEmpty ? 'No compatible standalone payload found.' : '');
        });
      }
    } finally {
      if (mounted) setState(() => payloadBusy = false);
    }
  }

  Future<void> downloadPayload() async {
    final selected = release!;
    setState(() {
      payloadBusy = true;
      payloadStatus = 'Downloading ${selected.tag}';
      payloadCancel = Cancellation();
    });
    try {
      final file = await c.payloads.download(selected, cancel: payloadCancel);
      if (mounted) {
        setState(() {
          payloadPath = file.path;
          payloadStatus = selected.digest == null
              ? 'Cached · release has no published checksum'
              : 'Cached · published SHA-256 verified';
        });
      }
      await _loadCached();
    } finally {
      if (mounted) setState(() => payloadBusy = false);
    }
  }

  Widget tools() => ListView(
    children: [
      title('UTILITIES', 'Make room to play', []),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.call_split, size: 34, color: accent),
              const SizedBox(height: 18),
              Text(
                'Split & merge',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 10),
              const Text(
                'FAT32-sized parts. One package when you need it.',
                style: TextStyle(color: muted),
              ),
              const SizedBox(height: 22),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  FilledButton(
                    onPressed: toolsBusy
                        ? null
                        : () => action(() => fileTool(split: true)),
                    child: const Text('Split a file'),
                  ),
                  OutlinedButton(
                    onPressed: toolsBusy
                        ? null
                        : () => action(() => fileTool(split: false)),
                    child: const Text('Merge a folder'),
                  ),
                  if (toolsBusy)
                    TextButton(
                      onPressed: () => toolsCancel?.cancel(),
                      child: const Text('Cancel'),
                    ),
                ],
              ),
              if (toolsBusy)
                const Padding(
                  padding: EdgeInsets.only(top: 18),
                  child: LinearProgressIndicator(),
                ),
              if (toolsStatus.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Text(
                    toolsStatus,
                    style: const TextStyle(color: muted),
                  ),
                ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 22),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'NS-USBloader / Flutter',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              const Text(
                'Independent desktop port · GPL-3.0-or-later\nBased on NS-USBloader by Dmitry Isaenko.',
                style: TextStyle(color: muted, height: 1.8),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () => showLicensePage(
                  context: context,
                  applicationName: 'NS-USBloader Flutter',
                  applicationVersion: '0.1.0',
                ),
                child: const Text('Open-source licenses'),
              ),
            ],
          ),
        ),
      ),
    ],
  );
  Future<void> fileTool({required bool split}) async {
    final sourcePath = split
        ? (await openFile())?.path
        : await getDirectoryPath();
    if (sourcePath == null) return;
    final target = await getSaveLocation(
      suggestedName: split
          ? '${p.basenameWithoutExtension(sourcePath)} (split)${p.extension(sourcePath)}'
          : p.basename(sourcePath),
    );
    if (target == null) return;
    setState(() {
      toolsBusy = true;
      toolsCancel = Cancellation();
      toolsStatus = split ? 'Splitting…' : 'Merging…';
    });
    try {
      final source = await FileSource.open(sourcePath);
      if (split) {
        await splitFile(source, target.path, cancel: toolsCancel);
      } else {
        await mergeFile(source, target.path, cancel: toolsCancel);
      }
      if (mounted) setState(() => toolsStatus = 'Saved ${target.path}');
    } on Cancelled {
      if (mounted) setState(() => toolsStatus = 'Cancelled');
    } catch (e) {
      if (mounted) setState(() => toolsStatus = 'Failed: $e');
      rethrow;
    } finally {
      if (mounted) setState(() => toolsBusy = false);
    }
  }
}

/// Original procedural cover art. No game artwork ships with the application.
class CoverPainter extends CustomPainter {
  final int seed;
  CoverPainter(this.seed);
  @override
  void paint(Canvas canvas, Size size) {
    final random = Random(seed);
    final hue = (seed.abs() % 360).toDouble();
    final colors = [
      HSVColor.fromAHSV(1, hue, .65, .46).toColor(),
      HSVColor.fromAHSV(1, (hue + 70) % 360, .8, .16).toColor(),
    ];
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
        ).createShader(Offset.zero & size),
    );
    for (var i = 0; i < 5; i++) {
      final origin = Offset(
        random.nextDouble() * size.width,
        random.nextDouble() * size.height,
      );
      canvas.drawCircle(
        origin,
        40 + random.nextDouble() * 100,
        Paint()
          ..color = Colors.white.withValues(alpha: .045)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 18 + random.nextDouble() * 28,
      );
    }
    final path = Path()
      ..moveTo(-20, size.height * .85)
      ..lineTo(size.width * .65, -30)
      ..lineTo(size.width + 30, -30)
      ..lineTo(size.width * .2, size.height + 30)
      ..close();
    canvas.drawPath(path, Paint()..color = Colors.white.withValues(alpha: .05));
  }

  @override
  bool shouldRepaint(CoverPainter old) => old.seed != seed;
}
