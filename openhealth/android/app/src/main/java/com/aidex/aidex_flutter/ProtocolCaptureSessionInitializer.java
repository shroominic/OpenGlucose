package com.aidex.aidex_flutter;

import java.io.IOException;

/** Initializes private capture storage and status before a recorder may start. */
final class ProtocolCaptureSessionInitializer {
  private ProtocolCaptureSessionInitializer() {}

  interface Preparation {
    void run() throws IOException;
  }

  static void initialize(
      Preparation prepareSession,
      Runnable requestCapture,
      Runnable updateReaderMode,
      Runnable publishReaderStatus,
      Runnable rollback)
      throws IOException {
    try {
      prepareSession.run();
      requestCapture.run();
      updateReaderMode.run();
      publishReaderStatus.run();
    } catch (IOException | RuntimeException error) {
      try {
        rollback.run();
      } catch (RuntimeException cleanupError) {
        error.addSuppressed(cleanupError);
      }
      throw error;
    }
  }
}
