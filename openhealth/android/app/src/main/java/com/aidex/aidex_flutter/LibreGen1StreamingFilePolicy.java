package com.aidex.aidex_flutter;

import java.io.DataInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.Arrays;

/** Pure receiver-file policy. Native adapters supply descriptor-bound metadata and I/O. */
final class LibreGen1StreamingFilePolicy {
  static final int MIN_ENVELOPE_BYTES = 30;
  static final int MAX_ENVELOPE_BYTES = 2048;

  static final class Metadata {
    final boolean directory, regular;
    final int owner, permissions;
    final long size;
    Metadata(boolean directory, boolean regular, int owner, int permissions, long size) {
      this.directory = directory;
      this.regular = regular;
      this.owner = owner;
      this.permissions = permissions;
      this.size = size;
    }
  }

  /** Only a positively observed native ENOENT may map to this result. */
  static final class AbsentFile extends IOException {}

  interface ReadHandle extends AutoCloseable {
    Metadata metadata() throws Exception;
    InputStream input();
    void close() throws Exception;
  }

  interface ReadAccess {
    Metadata directory() throws Exception;
    ReadHandle open() throws Exception;
  }

  interface WriteHandle extends AutoCloseable {
    Metadata metadata() throws Exception;
    OutputStream output();
    void sync() throws Exception;
    void close() throws Exception;
  }

  interface WriteAccess {
    Metadata directory() throws Exception;
    /** Null means positive absence; denied, malformed, or unknown paths must throw. */
    Metadata existing() throws Exception;
    WriteHandle createExclusive() throws Exception;
    void replace() throws Exception;
    void syncDirectory() throws Exception;
    /** Deletes only this operation's random staging file, never the destination. */
    void discardStaging() throws Exception;
  }

  private LibreGen1StreamingFilePolicy() {}

  static void requireDirectory(Metadata value, int owner) throws IOException {
    if (value == null || !value.directory || value.owner != owner) throw unavailable();
  }

  static void requireFile(Metadata value, int owner, long minimum, long maximum) throws IOException {
    if (value == null || !value.regular || value.owner != owner || value.permissions != 0600
        || value.size < minimum || value.size > maximum) throw unavailable();
  }

  static byte[] read(ReadAccess access, int owner) throws Exception {
    requireDirectory(access.directory(), owner);
    final ReadHandle opened;
    try { opened = access.open(); }
    catch (AbsentFile absent) { return null; }
    byte[] bytes = null;
    boolean complete = false;
    try {
      try (ReadHandle handle = opened) {
        final Metadata stat = handle.metadata();
        requireFile(stat, owner, MIN_ENVELOPE_BYTES, MAX_ENVELOPE_BYTES);
        bytes = new byte[(int) stat.size];
        final InputStream input = handle.input();
        new DataInputStream(input).readFully(bytes);
        if (input.read() != -1) throw unavailable();
        requireFile(handle.metadata(), owner, bytes.length, bytes.length);
      }
      complete = true;
      return bytes;
    } finally {
      // Includes descriptor-close failure: a partial or uncertain read is never returned.
      if (!complete && bytes != null) Arrays.fill(bytes, (byte) 0);
    }
  }

  static void write(WriteAccess access, int owner, byte[] envelope) throws Exception {
    if (envelope == null || envelope.length < MIN_ENVELOPE_BYTES
        || envelope.length > MAX_ENVELOPE_BYTES) throw unavailable();
    requireDirectory(access.directory(), owner);
    requireExisting(access.existing(), owner);
    boolean stagingCreated = false;
    boolean replaced = false;
    try {
      final WriteHandle created = access.createExclusive();
      stagingCreated = true;
      try (WriteHandle handle = created) {
        requireFile(handle.metadata(), owner, 0, 0);
        handle.output().write(envelope);
        handle.output().flush();
        handle.sync();
        requireFile(handle.metadata(), owner, envelope.length, envelope.length);
      }
      requireDirectory(access.directory(), owner);
      requireExisting(access.existing(), owner);
      access.replace();
      replaced = true;
      access.syncDirectory();
    } finally {
      // No rollback after rename. A later failure leaves the new encrypted journal intact.
      if (stagingCreated && !replaced) access.discardStaging();
    }
  }

  private static void requireExisting(Metadata value, int owner) throws IOException {
    if (value != null) requireFile(value, owner, MIN_ENVELOPE_BYTES, MAX_ENVELOPE_BYTES);
  }

  private static IOException unavailable() {
    return new IOException("Streaming storage is unavailable.");
  }
}
