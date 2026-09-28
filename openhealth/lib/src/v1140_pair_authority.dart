/// One-use native run authorization consumed before identity generation.
// ignore: one_member_abstracts
abstract interface class V1140OneShotAuthorization {
  Future<bool> consume({required String runNonce, required String storageKey});
}

final class V1140PairBuildBinding {
  V1140PairBuildBinding({
    required this.packageName,
    required this.signerSha256,
    required this.versionCode,
    required this.receiptSha256,
  }) {
    if (packageName != 'com.openglucose.app' ||
        !v1140CanonicalHash(signerSha256) ||
        versionCode <= 0 ||
        !v1140CanonicalHash(receiptSha256)) {
      throw ArgumentError('Invalid V1140 build binding.');
    }
  }
  final String packageName;
  final String signerSha256;
  final int versionCode;
  final String receiptSha256;
}

final class V1140InstalledAppIdentity {
  V1140InstalledAppIdentity({
    required this.packageName,
    required this.signerSha256,
    required this.versionCode,
    required this.uid,
    required this.debuggable,
  }) {
    if (packageName.isEmpty ||
        !v1140CanonicalHash(signerSha256) ||
        versionCode <= 0 ||
        uid < 0) {
      throw ArgumentError('Invalid V1140 installed identity.');
    }
  }
  final String packageName;
  final String signerSha256;
  final int versionCode;
  final int uid;
  final bool debuggable;
}

final class V1140RunClaim {
  V1140RunClaim({required this.runNonce, required this.expiresAtUtc}) {
    if (!v1140CanonicalHash(runNonce) ||
        !expiresAtUtc.isUtc ||
        expiresAtUtc.millisecondsSinceEpoch < 0) {
      throw ArgumentError('Invalid V1140 run claim.');
    }
  }
  final String runNonce;
  final DateTime expiresAtUtc;
}

bool v1140CanonicalHash(String value) =>
    RegExp(r'^[0-9a-f]{64}$').hasMatch(value);
