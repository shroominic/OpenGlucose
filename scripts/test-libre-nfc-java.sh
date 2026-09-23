#!/bin/sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
classes_dir=$(mktemp -d "${TMPDIR:-/tmp}/openglucose-libre-nfc-jvm.XXXXXX")

cleanup() {
  rm -R -- "$classes_dir"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

main_java="$repo_root/openhealth/android/app/src/main/java/com/aidex/aidex_flutter"
test_java="$repo_root/openhealth/android/app/src/test/java/com/aidex/aidex_flutter"

# Keep this list explicit: the bridge and secure store require Android APIs.
javac -d "$classes_dir" \
  "$main_java/Libre2ActivationUiProof.java" \
  "$main_java/Libre2Gen1ReadTransaction.java" \
  "$main_java/Libre2NfcSetupAttempt.java" \
  "$main_java/Libre2NfcSetupExpiryBinding.java" \
  "$main_java/LibreGen1Activation.java" \
  "$main_java/LibreGen1CalibrationEvidence.java" \
  "$main_java/LibreGen1CalibrationPersistence.java" \
  "$main_java/LibreGen1NfcFrames.java" \
  "$main_java/LibreGen1ReceiverReuseProof.java" \
  "$main_java/LibreGen1Streaming.java" \
  "$main_java/LibreGen1StreamingCalibration.java" \
  "$main_java/LibreGen1StreamingJournal.java" \
  "$main_java/NfcPublishedGrantEnvelope.java" \
  "$main_java/NfcRfReadiness.java" \
  "$main_java/NfcRfTransactionLease.java" \
  "$main_java/NfcRfTransactionLeaseBinding.java" \
  "$main_java/ProtocolCaptureSessionInitializer.java" \
  "$test_java/Libre2ActivationUiProofTest.java" \
  "$test_java/Libre2Gen1ReadTransactionTest.java" \
  "$test_java/Libre2NfcSetupAttemptTest.java" \
  "$test_java/Libre2NfcSetupExpiryBindingTest.java" \
  "$test_java/LibreGen1ActivationTest.java" \
  "$test_java/LibreGen1CalibrationEvidenceTest.java" \
  "$test_java/LibreGen1NfcFramesTest.java" \
  "$test_java/LibreGen1ReceiverReuseProofTest.java" \
  "$test_java/LibreGen1StreamingTest.java" \
  "$test_java/LibreGen1StreamingCalibrationTest.java" \
  "$test_java/NfcPublishedGrantEnvelopeTest.java" \
  "$test_java/NfcRfReadinessTest.java" \
  "$test_java/NfcRfTransactionLeaseTest.java" \
  "$test_java/NfcRfTransactionLeaseBindingTest.java" \
  "$test_java/ProtocolCaptureSessionInitializerTest.java"

for test_class in \
  Libre2ActivationUiProofTest \
  Libre2Gen1ReadTransactionTest \
  Libre2NfcSetupAttemptTest \
  Libre2NfcSetupExpiryBindingTest \
  LibreGen1ActivationTest \
  LibreGen1CalibrationEvidenceTest \
  LibreGen1NfcFramesTest \
  LibreGen1ReceiverReuseProofTest \
  LibreGen1StreamingTest \
  LibreGen1StreamingCalibrationTest \
  NfcPublishedGrantEnvelopeTest \
  NfcRfReadinessTest \
  NfcRfTransactionLeaseTest \
  NfcRfTransactionLeaseBindingTest \
  ProtocolCaptureSessionInitializerTest
do
  java -cp "$classes_dir" "com.aidex.aidex_flutter.$test_class"
done
