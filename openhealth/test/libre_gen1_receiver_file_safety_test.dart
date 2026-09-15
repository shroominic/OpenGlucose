import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const native = 'android/app/src/main/java/com/aidex/aidex_flutter/';

  test('receiver storage binds tested file policy to guarded native I/O', () {
    final store = File(
      '${native}LibreGen1StreamingStore.java',
    ).readAsStringSync();
    for (final required in [
      'LibreGen1StreamingFilePolicy.read(new NativeFiles()',
      'LibreGen1StreamingFilePolicy.write(files, owner, envelope)',
      'Os.lstat(',
      'Os.fstat(fd)',
      'OsConstants.O_NOFOLLOW',
      'OsConstants.O_NONBLOCK',
      'OsConstants.O_CREAT | OsConstants.O_EXCL | OsConstants.O_NOFOLLOW, 0600',
      'OsConstants.S_ISREG(stat.st_mode)',
      'stat.st_uid, stat.st_mode & 0777, stat.st_size',
      'output.getFD().sync()',
      'Os.fsync(fd)',
      'Os.rename(temporary.getAbsolutePath(), file.getAbsolutePath())',
    ]) {
      expect(store, contains(required), reason: required);
    }
    for (final forbidden in [
      '.exists()',
      '.isFile()',
      'new FileInputStream(file)',
      'new FileOutputStream(temporary)',
      'createNewFile()',
      'deleteEntry(',
      'transceive(',
      'removeBond(',
    ]) {
      expect(store, isNot(contains(forbidden)), reason: forbidden);
    }
    final read = store.substring(
      store.indexOf('@Override public byte[] read()'),
      store.indexOf('@Override public void write('),
    );
    expect(read, contains('key(false)'));
    expect(read, isNot(contains('key(true)')));
    expect(read, contains('Arrays.fill(encrypted, (byte) 0)'));
    final existing = store.substring(
      store.indexOf('public LibreGen1StreamingFilePolicy.Metadata existing()'),
      store.indexOf('public LibreGen1StreamingFilePolicy.ReadHandle open()'),
    );
    expect(
      existing,
      contains('if (failure.errno == OsConstants.ENOENT) return null'),
    );
    expect(existing, contains('throw failure'));
    final open = store.substring(
      store.indexOf('public LibreGen1StreamingFilePolicy.ReadHandle open()'),
      store.indexOf(
        'public LibreGen1StreamingFilePolicy.WriteHandle createExclusive()',
      ),
    );
    expect(
      open,
      contains(
        'if (failure.errno == OsConstants.ENOENT) throw new LibreGen1StreamingFilePolicy.AbsentFile()',
      ),
    );
    expect(open, contains('throw failure'));
  });

  test(
    'receiver hardening preserves encrypted format and prepared-abort boundary',
    () {
      final store = File(
        '${native}LibreGen1StreamingStore.java',
      ).readAsStringSync();
      expect(store, contains('context.getNoBackupFilesDir()'));
      expect(store, contains('"openglucose_libre_gen1_streaming_v1"'));
      expect(store, contains('"libre-gen1-streaming-v1.bin"'));
      expect(store, contains('{0x4f, 0x47, 0x4c, 0x32, 0x01}'));
      expect(store, contains('"AES/GCM/NoPadding"'));
      expect(store, contains('envelope[0] = 1'));
      final journal = File(
        '${native}LibreGen1StreamingJournal.java',
      ).readAsStringSync();
      final abort = journal.substring(
        journal.indexOf('synchronized void abortPrepared('),
        journal.indexOf('synchronized void commitIntent('),
      );
      expect(abort, contains('if (!current.state.equals("prepared")) throw'));
      expect(abort, contains('persist(null)'));
      expect(journal, contains('out.writeInt(1)'));
      expect(journal, contains('if (input.readInt() != 1)'));
      expect(journal, contains('current.unlockCount + 1'));
      expect(journal, contains('failed = true'));
    },
  );
}
