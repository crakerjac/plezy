// lib/services/plex_syncer_import_service.dart
//
// PlexSyncer import orchestrator.
//
// Owns all "import manifest → register in DB → download artwork" logic.
// DownloadProvider has zero knowledge of this flow — after doImport() returns,
// callers simply call downloadProvider.refresh() and the UI is consistent.
//
// This separation means download_provider.dart has no PlexSyncer-specific code,
// so it never conflicts with upstream merges.

import 'package:flutter/foundation.dart' show visibleForTesting;
import '../media/media_backend.dart';
import '../media/media_item.dart';
import '../media/media_kind.dart';
import '../media/media_server_client.dart';
import '../services/download_manager_service.dart';
import '../services/manifest_import_service.dart';
import '../utils/app_logger.dart';
import '../media/ids.dart';
import '../utils/global_key_utils.dart';

/// Summary returned by [PlexSyncerImportService.doImport].
class ImportSummary {
  final int imported;
  final int skipped;
  final int missing;
  final int pruned;
  final String? error;

  const ImportSummary({this.imported = 0, this.skipped = 0, this.missing = 0, this.pruned = 0, this.error});

  bool get hasError => error != null;

  String toUserMessage() {
    if (hasError) return error!;
    final buf = StringBuffer();
    if (imported > 0) buf.write('$imported item(s) added.');
    if (skipped > 0) buf.write(' $skipped already present.');
    if (pruned > 0) buf.write(' $pruned item(s) removed.');
    if (missing > 0) buf.write(' $missing file(s) not yet on device.');
    if (buf.isEmpty) buf.write('Everything up to date.');
    return buf.toString();
  }
}

class PlexSyncerImportService {
  static PlexSyncerImportService? _instance;
  static PlexSyncerImportService get instance => _instance ??= PlexSyncerImportService._();
  PlexSyncerImportService._();

  @visibleForTesting
  static void resetForTesting() => _instance = null;

  /// Read the manifest, register new items, prune stale ones.
  ///
  /// [clientResolver] — optional; when provided artwork is downloaded for
  /// newly imported items while the server is reachable.
  ///
  /// After this returns, call [DownloadProvider.refresh()] to sync in-memory
  /// state with the DB.
  Future<ImportSummary> doImport({
    required DownloadManagerService downloadManager,
    MediaServerClient? Function(String serverId)? clientResolver,
  }) async {
    final allExisting = await downloadManager.getAllDownloads();
    final existingKeys = {for (final d in allExisting) d.globalKey};

    final readResult = await ManifestImportService.instance.readManifest(knownGlobalKeys: existingKeys);

    if (readResult.hasError) {
      return ImportSummary(error: readResult.error);
    }

    final serverId = readResult.serverId;
    final serverName = readResult.serverName;
    int imported = 0;
    int skipped = readResult.manifestGlobalKeys.where(existingKeys.contains).length;
    int loopCount = 0;

    final fetchedShowKeys = <String>{};
    final stubbedParentKeys = <String>{};

    for (final item in readResult.resolved) {
      // Yield to the UI thread every 10 items to prevent jank on slow devices.
      if (++loopCount % 10 == 0) await Future.delayed(Duration.zero);

      final globalKey = buildGlobalKey(ServerId(serverId), item.ratingKey);
      if (existingKeys.contains(globalKey)) {
        skipped++;
        continue;
      }

      final kind = MediaKind.fromString(item.type);
      final metadata = MediaItem(
        id: item.ratingKey,
        backend: MediaBackend.plex,
        kind: kind,
        title: item.title,
        summary: item.summary,
        thumbPath: item.thumb,
        artPath: item.art,
        durationMs: item.duration,
        year: kind == MediaKind.movie ? item.year : null,
        index: item.episodeNumber,
        parentId: item.parentRatingKey,
        parentTitle: item.parentTitle,
        parentThumbPath: item.parentThumb,
        parentIndex: item.seasonNumber,
        grandparentId: item.grandparentRatingKey,
        grandparentTitle: item.grandparentTitle,
        grandparentThumbPath: item.grandparentThumb,
        grandparentArtPath: item.grandparentArt,
        serverId: serverId,
        serverName: serverName,
      );

      if (kind == MediaKind.episode) {
        if (item.grandparentRatingKey?.isNotEmpty == true && stubbedParentKeys.add(item.grandparentRatingKey!)) {
          await downloadManager.registerSyncedParentStub(
            MediaItem(
              id: item.grandparentRatingKey!,
              backend: MediaBackend.plex,
              kind: MediaKind.show,
              title: item.grandparentTitle,
              thumbPath: item.grandparentThumb,
              artPath: item.grandparentArt,
              year: item.grandparentYear,
              serverId: serverId,
              serverName: serverName,
            ),
          );
        }
        if (item.parentRatingKey?.isNotEmpty == true && stubbedParentKeys.add(item.parentRatingKey!)) {
          await downloadManager.registerSyncedParentStub(
            MediaItem(
              id: item.parentRatingKey!,
              backend: MediaBackend.plex,
              kind: MediaKind.season,
              title: item.parentTitle,
              thumbPath: item.parentThumb ?? item.grandparentThumb,
              parentIndex: item.seasonNumber,
              grandparentId: item.grandparentRatingKey,
              grandparentTitle: item.grandparentTitle,
              serverId: serverId,
              serverName: serverName,
            ),
          );
        }
      }

      await downloadManager.registerSyncedDownload(metadata: metadata, fileUri: item.fileUri, thumbPath: item.thumb);

      if (clientResolver != null) {
        final client = clientResolver(serverId);
        if (client != null) {
          await downloadManager.downloadArtworkForMetadata(metadata, client);
          if (kind == MediaKind.episode &&
              item.grandparentRatingKey?.isNotEmpty == true &&
              fetchedShowKeys.add(item.grandparentRatingKey!)) {
            await downloadManager.downloadArtworkForMetadata(
              MediaItem(
                id: item.grandparentRatingKey!,
                backend: MediaBackend.plex,
                kind: MediaKind.show,
                thumbPath: item.grandparentThumb,
                artPath: item.grandparentArt,
                serverId: serverId,
                serverName: serverName,
              ),
              client,
            );
          }
        }
      }

      imported++;
    }

    // Prune stale PlexSyncer items: DB entries whose videoFilePath is a SAF
    // URI under the PlexSyncer folder but are no longer in the manifest.
    int pruned = 0;
    if (readResult.psRootUri.isNotEmpty) {
      final psDocId = Uri.parse(readResult.psRootUri).pathSegments.last;
      for (final row in allExisting) {
        final filePath = row.videoFilePath;
        if (filePath == null || !filePath.startsWith('content://')) continue;
        final fileDocId = Uri.parse(filePath).pathSegments.last;
        if (!fileDocId.startsWith(psDocId)) continue;
        if (readResult.manifestGlobalKeys.contains(row.globalKey)) continue;

        appLogger.i('PlexSyncer prune: removing stale row ${row.globalKey}');
        try {
          await downloadManager.deleteDownload(row.globalKey);
          pruned++;
        } catch (e) {
          appLogger.w('PlexSyncer prune: failed to remove ${row.globalKey}', error: e);
        }
      }
      if (pruned > 0) appLogger.i('PlexSyncer: pruned $pruned stale item(s)');
    }

    if (readResult.generatedAt.isNotEmpty) {
      await ManifestImportService.instance.markImported(readResult.generatedAt);
    }

    return ImportSummary(imported: imported, skipped: skipped, missing: readResult.missing, pruned: pruned);
  }
}
