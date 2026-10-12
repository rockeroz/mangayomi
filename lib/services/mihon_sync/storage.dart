// Small JSON files used by Mihon Sync: journal, remote cache, category identities,
// Mihon source ids and settings. Each file is replaced through a temporary file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mangayomi/services/mihon_sync/protocol.dart';
import 'package:mangayomi/services/mihon_sync/remote.dart';
import 'package:mangayomi/services/mihon_sync/session.dart';
import 'package:path_provider/path_provider.dart';

class JsonFile {
  final File file;
  JsonFile(this.file);

  Object? read() {
    final target = file.existsSync() ? file : File('${file.path}.bak');
    if (!target.existsSync()) return null;
    return jsonDecode(target.readAsStringSync());
  }

  void write(Object? json) {
    file.parent.createSync(recursive: true);
    final temporary = File('${file.path}.tmp');
    temporary.writeAsStringSync(jsonEncode(json), flush: true);
    if (file.existsSync()) {
      final backup = File('${file.path}.bak');
      if (backup.existsSync()) backup.deleteSync();
      file.renameSync(backup.path);
    }
    temporary.renameSync(file.path);
    final backup = File('${file.path}.bak');
    if (backup.existsSync()) backup.deleteSync();
  }
}

Future<Directory> mihonSyncDirectory() async {
  final support = await getApplicationSupportDirectory();
  final directory = Directory('${support.path}${Platform.pathSeparator}mihon-sync');
  directory.createSync(recursive: true);
  return directory;
}

class FileJournalStore implements SyncJournalStore {
  final JsonFile _file;
  FileJournalStore(File file) : _file = JsonFile(file);

  @override
  SyncJournal read() {
    try {
      return SyncJournal.fromJson(_file.read());
    } on SyncFormatException {
      throw SyncFailure(SyncFailureReason.format);
    }
  }

  @override
  void write(SyncJournal journal) => _file.write(journal.toJson());
}

class FileIncrementalCacheStore implements IncrementalCacheStore {
  final JsonFile _file;
  FileIncrementalCacheStore(File file) : _file = JsonFile(file);

  @override
  IncrementalCache read() => IncrementalCache.fromJson(_file.read());

  @override
  void write(IncrementalCache cache) => _file.write(cache.toJson());
}

/// Mangayomi stores Mihon extension sources under `'mihon-<id>'.hashCode`. This remembers the
/// original Mihon source id, which the shared document uses, for every hashed id seen.
class MihonSourceIds {
  static final MihonSourceIds instance = MihonSourceIds._();
  MihonSourceIds._();

  final Map<int, int> _byLocalId = {};
  JsonFile? _file;
  bool _dirty = false;

  static int localIdFor(int mihonId) => 'mihon-$mihonId'.hashCode;

  Future<void> load() async {
    if (_file != null) return;
    final directory = await mihonSyncDirectory();
    _file = JsonFile(File('${directory.path}${Platform.pathSeparator}source-ids.json'));
    try {
      final json = _file!.read();
      if (json is Map) {
        json.forEach((key, value) {
          final local = int.tryParse('$key');
          final mihon = int.tryParse('$value');
          if (local != null && mihon != null) _byLocalId[local] = mihon;
        });
      }
    } catch (_) {
      // The registry is rebuilt from the extension lists.
    }
    if (_dirty) _scheduleSave();
  }

  /// Called wherever Mangayomi builds a Mihon source from a repository listing, with the same
  /// raw value Mangayomi hashes.
  void remember(Object? mihonId) {
    final id = int.tryParse('$mihonId');
    if (id == null) return;
    final local = 'mihon-$mihonId'.hashCode;
    if (_byLocalId[local] == id) return;
    _byLocalId[local] = id;
    _dirty = true;
    _scheduleSave();
  }

  int? mihonIdFor(int? localId) => localId == null ? null : _byLocalId[localId];

  /// The local source id for a Mihon source id: a remembered one, else Mangayomi's hash.
  int localIdForMihon(int mihonId) {
    for (final entry in _byLocalId.entries) {
      if (entry.value == mihonId) return entry.key;
    }
    return localIdFor(mihonId);
  }

  /// Records an id pair confirmed by an existing source row.
  void confirm(int localId, int mihonId) {
    if (_byLocalId[localId] == mihonId) return;
    _byLocalId[localId] = mihonId;
    _dirty = true;
    _scheduleSave();
  }

  Timer? _saveTimer;

  void _scheduleSave() {
    if (_file == null || _saveTimer != null) return;
    _saveTimer = Timer(const Duration(seconds: 2), () {
      _saveTimer = null;
      _save();
    });
  }

  void _save() {
    try {
      _file?.write({for (final e in _byLocalId.entries) '${e.key}': '${e.value}'});
      _dirty = false;
    } catch (_) {
      // Retried on the next change.
    }
  }
}
