package com.aidex.aidex_flutter;

/**
 * In-process identity binding for the cross-process NFC RF lease.
 *
 * <p>A host-authorized transaction has no explicit attempt. An explicit UI
 * transaction is bound to the exact attempt object, so a stale callback from
 * an older attempt cannot take or release a newer attempt's filesystem lease.
 */
final class NfcRfTransactionLeaseBinding {
  private NfcRfTransactionLease lease;
  private Libre2NfcSetupAttempt explicitAttempt;
  private boolean maintenance;

  synchronized boolean isEmpty() {
    return lease == null;
  }

  synchronized boolean bindHost(NfcRfTransactionLease acquiredLease) {
    if (acquiredLease == null || lease != null) {
      return false;
    }
    lease = acquiredLease;
    explicitAttempt = null;
    maintenance = false;
    return true;
  }

  synchronized boolean bindMaintenance(
      NfcRfTransactionLease acquiredLease) {
    if (acquiredLease == null || lease != null) {
      return false;
    }
    lease = acquiredLease;
    explicitAttempt = null;
    maintenance = true;
    return true;
  }

  synchronized boolean bindExplicit(
      Libre2NfcSetupAttempt attempt,
      NfcRfTransactionLease acquiredLease) {
    if (attempt == null || acquiredLease == null || lease != null) {
      return false;
    }
    lease = acquiredLease;
    explicitAttempt = attempt;
    maintenance = false;
    return true;
  }

  synchronized boolean isHeldByHost(
      NfcRfTransactionLease expectedLease) {
    return expectedLease != null
        && lease == expectedLease
        && !maintenance
        && explicitAttempt == null
        && lease.isHeldByThisOwner();
  }

  synchronized boolean isHeldByExplicitAttempt(
      Libre2NfcSetupAttempt attempt) {
    return lease != null
        && !maintenance
        && explicitAttempt == attempt
        && lease.isHeldByThisOwner();
  }

  synchronized NfcRfTransactionLease takeHost(
      NfcRfTransactionLease expectedLease) {
    if (lease == null
        || lease != expectedLease
        || maintenance
        || explicitAttempt != null) {
      return null;
    }
    return takeAnyLocked();
  }

  synchronized NfcRfTransactionLease takeExplicit(
      Libre2NfcSetupAttempt attempt) {
    if (lease == null || maintenance || explicitAttempt != attempt) {
      return null;
    }
    return takeAnyLocked();
  }

  synchronized NfcRfTransactionLease claimHostForMaintenance(
      NfcRfTransactionLease expectedLease) {
    if (lease == null
        || lease != expectedLease
        || maintenance
        || explicitAttempt != null) {
      return null;
    }
    maintenance = true;
    return lease;
  }

  synchronized NfcRfTransactionLease claimExplicitForMaintenance(
      Libre2NfcSetupAttempt attempt) {
    if (lease == null
        || maintenance
        || attempt == null
        || explicitAttempt != attempt) {
      return null;
    }
    explicitAttempt = null;
    maintenance = true;
    return lease;
  }

  synchronized boolean isHeldByMaintenance(
      NfcRfTransactionLease expectedLease) {
    return expectedLease != null
        && lease == expectedLease
        && maintenance
        && lease.isHeldByThisOwner();
  }

  synchronized NfcRfTransactionLease takeMaintenance(
      NfcRfTransactionLease expectedLease) {
    if (lease == null || lease != expectedLease || !maintenance) {
      return null;
    }
    return takeAnyLocked();
  }

  private NfcRfTransactionLease takeAnyLocked() {
    final NfcRfTransactionLease result = lease;
    lease = null;
    explicitAttempt = null;
    maintenance = false;
    return result;
  }
}
