// One synchronization pass, ported from Mihon Sync 0.7.2 (DeviceSyncSession).
//
// The journal keeps the last synchronized document (baseline), the local candidate being
// uploaded (pending) and a received document not yet applied (incoming), so a crash or a
// lost network response never loses local changes or applies remote data twice.

import 'package:mangayomi/services/mihon_sync/merger.dart';
import 'package:mangayomi/services/mihon_sync/protocol.dart';
import 'package:mangayomi/services/mihon_sync/remote.dart';

enum SyncStage {
  serverTest,
  journalRead,
  localRead,
  prepare,
  journalWrite,
  download,
  decode,
  merge,
  upload,
  localApply,
}

class SyncStageFailure implements Exception {
  final SyncStage stage;
  final Object error;
  final StackTrace? stackTrace;
  SyncStageFailure(this.stage, this.error, [this.stackTrace]);

  @override
  String toString() => 'SyncStageFailure(${stage.name}): $error';
}

Future<T> syncStage<T>(SyncStage stage, Future<T> Function() action) async {
  try {
    return await action();
  } on SyncStageFailure {
    rethrow;
  } catch (error, stackTrace) {
    throw SyncStageFailure(stage, error, stackTrace);
  }
}

class SyncJournal {
  final SyncDocument baseline;
  final SyncDocument? pending;
  final SyncDocument? incoming;

  /// ETag of the remote document whose content is exactly [baseline], when known.
  final String? baselineEtag;
  final SyncOptions options;

  const SyncJournal({
    this.baseline = const SyncDocument(),
    this.pending,
    this.incoming,
    this.baselineEtag,
    this.options = const SyncOptions(),
  });

  SyncJournal copyWith({
    SyncDocument? pending,
    bool clearPending = false,
    SyncDocument? incoming,
    bool clearIncoming = false,
    SyncOptions? options,
  }) => SyncJournal(
    baseline: baseline,
    pending: clearPending ? null : (pending ?? this.pending),
    incoming: clearIncoming ? null : (incoming ?? this.incoming),
    baselineEtag: baselineEtag,
    options: options ?? this.options,
  );

  factory SyncJournal.fromJson(Object? json) {
    if (json is! Map) return const SyncJournal();
    SyncDocument? document(String key) =>
        json[key] == null ? null : (SyncDocument.fromJson(json[key])..validate());
    return SyncJournal(
      baseline: document('baseline') ?? const SyncDocument(),
      pending: document('pending'),
      incoming: document('incoming'),
      baselineEtag: json['baselineEtag'] as String?,
      options: SyncOptions.fromJson(json['options']),
    );
  }

  Map<String, dynamic> toJson() => {
    'baseline': baseline.toJson(),
    if (pending != null) 'pending': pending!.toJson(),
    if (incoming != null) 'incoming': incoming!.toJson(),
    if (baselineEtag != null) 'baselineEtag': baselineEtag,
    'options': options.toJson(),
  };
}

abstract class SyncJournalStore {
  SyncJournal read();
  void write(SyncJournal journal);
}

/// Reads and writes this app's library in the shared format.
abstract class SyncLibraryRepository {
  /// Values read in one database transaction.
  Future<SyncSnapshot> snapshot(SyncDocument known);

  /// Applies [remote], keeping local edits made after [observed] was read.
  Future<void> apply(SyncDocument remote, SyncSnapshot observed);
}

class _Accepted {
  final String? etag;
  const _Accepted(this.etag);
}

class MihonSyncSession {
  final SyncLibraryRepository repository;
  final SyncRemoteStore remote;
  final SyncJournalStore store;
  final String device;
  final bool Function() readerOpen;
  final int Function() now;
  final SyncOptions options;
  final void Function(SyncStage stage) phase;

  /// On the first pass of a newly linked library, entries that already exist on the server
  /// take the server's state instead of competing with possibly older local data.
  final bool preferRemoteOnFirstSync;

  MihonSyncSession({
    required this.repository,
    required this.remote,
    required this.store,
    required this.device,
    required this.readerOpen,
    int Function()? now,
    this.options = SyncOptions.mangayomi,
    this.preferRemoteOnFirstSync = true,
    void Function(SyncStage stage)? phase,
  }) : now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
       phase = phase ?? ((_) {});

  /// True when the remote document was applied; false when a reader kept it pending.
  Future<bool> sync() async {
    final selected = options;
    phase(SyncStage.localRead);
    final journal = await syncStage(SyncStage.journalRead, () async => store.read());
    final comparison = SyncCategories.upgrade(journal.pending ?? journal.baseline);
    final known = await syncStage(
      SyncStage.prepare,
      () async => SyncMerger.merge(comparison, journal.incoming ?? const SyncDocument()),
    );
    final observed = await syncStage(SyncStage.localRead, () => repository.snapshot(known));
    var captured = observed;
    final pristine =
        journal.pending == null &&
        journal.incoming == null &&
        journal.baselineEtag == null &&
        journal.baseline == const SyncDocument();
    if (preferRemoteOnFirstSync && pristine) {
      phase(SyncStage.download);
      final first = await syncStage(SyncStage.download, () => remote.read());
      final existing = await syncStage(SyncStage.decode, () async {
        if (first.document != null) return first.document!;
        final content = first.content;
        return content == null ? const SyncDocument() : decodeSyncDocument(content);
      });
      final upgraded = SyncCategories.upgrade(existing);
      final keys = {for (final manga in upgraded.mangas) manga.key};
      final categories = {for (final category in upgraded.categoryDefinitions) category.id};
      captured = observed.copyWith(
        mangas: [
          for (final manga in observed.mangas)
            if (!keys.contains(manga.key)) manga,
        ],
        categoryDefinitions: [
          for (final category in observed.categoryDefinitions)
            if (!categories.contains(category.id)) category,
        ],
      );
    }
    final candidate = await syncStage(
      SyncStage.prepare,
      () async => SyncMerger.merge(
        SyncMerger.capture(
          selected.captureBaseline(comparison, journal.options),
          selected.captureSnapshot(captured, comparison),
          device,
          now(),
          journal.incoming,
        ),
        SyncMerger.merge(comparison, journal.incoming ?? const SyncDocument()),
      ),
    );
    await syncStage(
      SyncStage.journalWrite,
      () async => store.write(
        journal.copyWith(pending: candidate, clearIncoming: true, options: selected),
      ),
    );
    for (var attempt = 0; attempt < 4; attempt++) {
      // The first read is conditional: while the remote document is still the one this device
      // last synchronized, the server answers 304 and the baseline stands in for it.
      final cachedEtag = attempt == 0 ? journal.baselineEtag : null;
      phase(SyncStage.download);
      final file = await syncStage(
        SyncStage.download,
        () => cachedEtag != null ? remote.readIfChanged(cachedEtag) : remote.read(),
      );
      final exists = file == null || file.content != null;
      final etag = file == null ? cachedEtag : file.etag;
      final document = await syncStage(SyncStage.decode, () async {
        if (file == null) return journal.baseline;
        if (file.document != null) return file.document!;
        final content = file.content;
        return content == null ? const SyncDocument() : decodeSyncDocument(content);
      });
      final merged = await syncStage(
        SyncStage.merge,
        () async => SyncMerger.merge(candidate, document),
      );
      // Reading an already converged document must not trigger another full upload.
      final _Accepted? accepted;
      if (merged == document && exists && !remote.needsInitialization()) {
        accepted = _Accepted(etag);
      } else {
        phase(SyncStage.upload);
        accepted = await syncStage(SyncStage.upload, () async {
          try {
            final result = await remote.put(merged, etag);
            return result.accepted ? _Accepted(result.etag) : null;
          } on SyncFailure catch (error) {
            // A timed-out upload may have been stored. Confirm the entire document before using it.
            if (error.reason != SyncFailureReason.network || !await _confirmUpload(merged)) {
              rethrow;
            }
            return const _Accepted(null);
          }
        });
      }
      if (accepted != null) {
        await syncStage(
          SyncStage.journalWrite,
          () async => store.write(
            journal.copyWith(pending: candidate, incoming: merged, options: selected),
          ),
        );
        if (readerOpen()) return false;
        phase(SyncStage.localApply);
        await syncStage(
          SyncStage.localApply,
          () => repository.apply(selected.applyDocument(merged, observed), observed),
        );
        await syncStage(
          SyncStage.journalWrite,
          () async => store.write(
            SyncJournal(baseline: merged, baselineEtag: accepted!.etag, options: selected),
          ),
        );
        return true;
      }
    }
    throw SyncFailure(SyncFailureReason.busy);
  }

  Future<bool> _confirmUpload(SyncDocument expected) async {
    try {
      final file = await remote.read();
      if (file.content == null || file.etag == null) return false;
      return (file.document ?? decodeSyncDocument(file.content!)) == expected;
    } catch (_) {
      return false;
    }
  }
}
