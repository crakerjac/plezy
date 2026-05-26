import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import '../../focus/focusable_action_bar.dart';
import '../../media/media_item.dart';
import '../../providers/download_provider.dart';
import '../../providers/multi_server_provider.dart';
import '../../services/settings_service.dart';
import '../../widgets/settings_builder.dart';
import '../../utils/global_key_utils.dart';
import '../../mixins/tab_navigation_mixin.dart';
import '../../mixins/refreshable.dart';
import '../../utils/grid_size_calculator.dart';
import '../../utils/platform_detector.dart';
import '../../widgets/desktop_app_bar.dart';
import '../../widgets/focusable_tab_chip.dart';
import '../../widgets/focusable_media_card.dart';
import '../../widgets/media_grid_delegate.dart';
import '../../widgets/download_tree_view.dart';
import '../main_screen.dart';
import '../libraries/state_messages.dart';
import '../../i18n/strings.g.dart';
import 'sync_rules_screen.dart';
import '../../services/manifest_import_service.dart';
import '../../utils/app_logger.dart';

class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({super.key});

  @override
  State<DownloadsScreen> createState() => DownloadsScreenState();
}

class DownloadsScreenState extends State<DownloadsScreen>
    with TickerProviderStateMixin, TabNavigationMixin, FocusableTab {
  // Focus nodes for tab chips
  final _queueTabChipFocusNode = FocusNode(debugLabel: 'tab_chip_queue');
  final _tvShowsTabChipFocusNode = FocusNode(debugLabel: 'tab_chip_tv_shows');
  final _moviesTabChipFocusNode = FocusNode(debugLabel: 'tab_chip_movies');
  final _actionBarKey = GlobalKey<FocusableActionBarState>();
  bool _isImporting = false;

  @override
  List<FocusNode> get tabChipFocusNodes => [_queueTabChipFocusNode, _tvShowsTabChipFocusNode, _moviesTabChipFocusNode];

  @override
  void initState() {
    super.initState();
    suppressAutoFocus = true; // Start suppressed
    initTabNavigation();
    // PlexSyncer: check if manifest updated since last scan
    WidgetsBinding.instance.addPostFrameCallback((_) => _autoCheckManifest());
  }

  // PlexSyncer: notify-only check on nav — shows a snackbar if manifest has
  // been updated since last import, letting the user decide when to import.
  Future<void> _autoCheckManifest() async {
    if (!mounted) return;
    try {
      final hasUpdate = await ManifestImportService.instance.checkForUpdates();
      if (!mounted || !hasUpdate) return;
      appLogger.i('PlexSyncer: manifest updated — notifying user');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('PlexSyncer folder updated — tap to import'),
        duration: const Duration(seconds: 8),
        action: SnackBarAction(
          label: 'Import',
          onPressed: _importFromManifest,
        ),
      ));
    } catch (e) {
      appLogger.d('PlexSyncer: auto-check failed: $e');
    }
  }

  // PlexSyncer: import synced files from the PlexSyncer manifest.json.
  // Button spins and is disabled while running; no blocking dialog.
  Future<void> _importFromManifest() async {
    if (!mounted || _isImporting) return;
    setState(() => _isImporting = true);

    try {
      final serverProvider = context.read<MultiServerProvider>();
      final summary = await context.read<DownloadProvider>().importFromManifest(
        clientResolver: (id) => serverProvider.serverManager.getClient(id),
      );

      if (!mounted) return;

      if (summary.hasError) {
        showDialog<void>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Scan failed'),
            content: Text(summary.error!),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('OK'),
              ),
            ],
          ),
        );
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(summary.toUserMessage()),
        duration: const Duration(seconds: 5),
      ));
    } finally {
      if (mounted) setState(() => _isImporting = false);
    }
  }

  @override
  void dispose() {
    _queueTabChipFocusNode.dispose();
    _tvShowsTabChipFocusNode.dispose();
    _moviesTabChipFocusNode.dispose();
    disposeTabNavigation();
    super.dispose();
  }

  @override
  void onTabChanged() {
    if (!tabController.indexIsChanging) {
      super.onTabChanged();
    }
  }

  @override
  void focusActiveTabIfReady() {
    suppressAutoFocus = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      getTabChipFocusNode(tabController.index).requestFocus();
    });
  }

  /// Focus the first item in the currently active tab
  void _focusCurrentTab() {
    // Re-enable auto-focus since user is navigating into tab content
    setState(() {
      suppressAutoFocus = false;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Focus will be handled by the tab content
    });
  }

  Widget _buildTabChip(String label, int index) {
    final isSelected = tabController.index == index;

    return FocusableTabChip(
      label: label,
      isSelected: isSelected,
      focusNode: getTabChipFocusNode(index),
      onSelect: () {
        if (isSelected) {
          // Already selected - navigate to tab content
          _focusCurrentTab();
        } else {
          // Switch to this tab
          setState(() {
            tabController.index = index;
          });
        }
      },
      onNavigateLeft: index > 0
          ? () {
              final newIndex = index - 1;
              setState(() {
                suppressAutoFocus = true;
                tabController.index = newIndex;
              });
              getTabChipFocusNode(newIndex).requestFocus();
            }
          : onTabBarBack,
      onNavigateRight: index < tabCount - 1
          ? () {
              final newIndex = index + 1;
              setState(() {
                suppressAutoFocus = true;
                tabController.index = newIndex;
              });
              getTabChipFocusNode(newIndex).requestFocus();
            }
          : () => _actionBarKey.currentState?.requestFocusOnFirst(),
      onNavigateDown: _focusCurrentTab,
      onBack: onTabBarBack,
    );
  }

  /// Build the app bar title - either tabs on desktop or simple title on mobile
  Widget _buildAppBarTitle() {
    // On desktop/TV with side nav, show tabs in app bar
    if (PlatformDetector.shouldUseSideNavigation(context)) {
      return Row(
        children: [
          _buildTabChip(t.downloads.manage, 0),
          const SizedBox(width: 8),
          _buildTabChip(t.downloads.tvShows, 1),
          const SizedBox(width: 8),
          _buildTabChip(t.downloads.movies, 2),
        ],
      );
    }

    // On mobile, show simple title
    return Text(t.downloads.title);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: CustomScrollView(
        primary: false,
        slivers: [
          DesktopSliverAppBar(
            title: _buildAppBarTitle(),
            floating: true,
            pinned: true,
            backgroundColor: Theme.of(context).scaffoldBackgroundColor,
            surfaceTintColor: Colors.transparent,
            shadowColor: Colors.transparent,
            scrolledUnderElevation: 0,
            // PlexSyncer + upstream: both actions in one FocusableActionBar
            actions: [
              FocusableActionBar(
                key: _actionBarKey,
                onNavigateLeft: () => getTabChipFocusNode(tabCount - 1).requestFocus(),
                onNavigateDown: _focusCurrentTab,
                // PlexSyncer + upstream: both actions in one FocusableActionBar
                actions: [
                  FocusableAction(
                    icon: Symbols.rule_settings,
                    tooltip: t.downloads.activeSyncRules,
                    onPressed: () =>
                        Navigator.push(context, MaterialPageRoute(builder: (_) => const SyncRulesScreen())),
                  ),
                  // PlexSyncer: scan button — spins and disables while importing
                  FocusableAction(
                    icon: Icons.drive_file_move_rtl_outlined,
                    tooltip: 'Scan PlexSyncer folder',
                    onPressed: _isImporting ? null : _importFromManifest,
                    child: _isImporting
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : null,
                  ),
                ],
              ),
            ],
          ),
          SliverFillRemaining(
            child: Column(
              children: [
                // Tab selector chips (only on mobile - desktop has them in app bar)
                if (!PlatformDetector.shouldUseSideNavigation(context))
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    alignment: Alignment.centerLeft,
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          _buildTabChip(t.downloads.manage, 0),
                          const SizedBox(width: 8),
                          _buildTabChip(t.downloads.tvShows, 1),
                          const SizedBox(width: 8),
                          _buildTabChip(t.downloads.movies, 2),
                        ],
                      ),
                    ),
                  ),
                // Tab content
                Expanded(
                  child: TabBarView(
                    controller: tabController,
                    children: [
                      Consumer2<DownloadProvider, MultiServerProvider>(
                        builder: (context, downloadProvider, serverProvider, _) {
                          // Resolve the owning server's client from a download's
                          // globalKey (`serverId:ratingKey`). Backend-neutral —
                          // Jellyfin downloads also surface here, so the
                          // resume/retry buttons need a [MediaServerClient]
                          // (not a [PlexClient]) for both code paths.
                          getClient(String globalKey) {
                            final serverId = parseGlobalKey(globalKey)?.serverId ?? globalKey;
                            return serverProvider.serverManager.getClient(serverId);
                          }

                          return DownloadTreeView(
                            downloads: downloadProvider.downloads,
                            metadata: downloadProvider.metadata,
                            onPause: downloadProvider.pauseDownload,
                            onResume: (globalKey) {
                              final client = getClient(globalKey);
                              if (client != null) {
                                downloadProvider.resumeDownload(globalKey, client);
                              }
                            },
                            onRetry: (globalKey) {
                              final client = getClient(globalKey);
                              if (client != null) {
                                downloadProvider.retryDownload(globalKey, client);
                              }
                            },
                            onCancel: downloadProvider.cancelDownload,
                            onDelete: downloadProvider.deleteDownload,
                            onNavigateLeft: () => MainScreenFocusScope.of(context, listen: false)?.focusSidebar(),
                            onBack: focusTabBar,
                            suppressAutoFocus: suppressAutoFocus,
                          );
                        },
                      ),
                      _DownloadsGridContent(
                        type: DownloadType.tvShows,
                        suppressAutoFocus: suppressAutoFocus,
                        onBack: focusTabBar,
                      ),
                      _DownloadsGridContent(
                        type: DownloadType.movies,
                        suppressAutoFocus: suppressAutoFocus,
                        onBack: focusTabBar,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

enum DownloadType { manage, tvShows, movies }

/// Grid content for TV Shows and Movies tabs
class _DownloadsGridContent extends StatefulWidget {
  final DownloadType type;
  final bool suppressAutoFocus;
  final VoidCallback? onBack;

  const _DownloadsGridContent({required this.type, required this.suppressAutoFocus, this.onBack});

  @override
  State<_DownloadsGridContent> createState() => _DownloadsGridContentState();
}

class _DownloadsGridContentState extends State<_DownloadsGridContent> {
  final FocusNode _firstItemFocusNode = FocusNode(debugLabel: 'DownloadsGrid_firstItem');

  @override
  void dispose() {
    _firstItemFocusNode.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(_DownloadsGridContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    // When suppressAutoFocus changes from true to false, focus the first item
    if (oldWidget.suppressAutoFocus && !widget.suppressAutoFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _firstItemFocusNode.canRequestFocus) {
          _firstItemFocusNode.requestFocus();
        }
      });
    }
  }

  /// Navigate focus to the sidebar
  void _navigateToSidebar() {
    MainScreenFocusScope.of(context, listen: false)?.focusSidebar();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<DownloadProvider>(
      builder: (context, downloadProvider, _) {
        final List<MediaItem> items = widget.type == DownloadType.tvShows
            ? downloadProvider.downloadedShows
            : downloadProvider.downloadedMovies;

        if (items.isEmpty) {
          return _buildEmptyState();
        }

        // Extra top padding for focus decoration (scale + border extends beyond item bounds)
        const effectivePadding = EdgeInsets.only(left: 8, right: 8, top: 8);

        return SettingValueBuilder<int>(
          pref: SettingsService.libraryDensity,
          builder: (context, density, _) {
            final maxCrossAxisExtent = GridSizeCalculator.getMaxCrossAxisExtent(context, density);
            // Use LayoutBuilder to get actual available width (accounting for sidebar)
            return LayoutBuilder(
              builder: (context, constraints) {
                final availableWidth = constraints.maxWidth - effectivePadding.left - effectivePadding.right;
                final columnCount = GridSizeCalculator.getColumnCount(availableWidth, maxCrossAxisExtent);

                return GridView.builder(
                  padding: effectivePadding,
                  // Allow focus decoration to render outside scroll bounds
                  clipBehavior: Clip.none,
                  gridDelegate: MediaGridDelegate.createDelegate(context: context, density: density),
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final item = items[index];
                    final isFirstColumn = GridSizeCalculator.isFirstColumn(index, columnCount);
                    final isFirst = index == 0;
                    return FocusableMediaCard(
                      item: item,
                      focusNode: isFirst ? _firstItemFocusNode : null,
                      onBack: widget.onBack,
                      isOffline: true, // Downloaded content works without server
                      onNavigateLeft: isFirstColumn ? _navigateToSidebar : null,
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildEmptyState() {
    return EmptyStateWidget(
      message: t.downloads.noDownloads,
      subtitle: t.downloads.noDownloadsDescription,
      icon: Symbols.download_rounded,
      iconSize: 80,
    );
  }
}
