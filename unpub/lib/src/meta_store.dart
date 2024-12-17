import 'package:unpub/src/models.dart';

abstract class MetaStore {
  Future<UnpubPackage?> queryPackage(
    String name, {
    bool versionsSortAsc = true,
  });

  Future<UnpubPackage?> queryPackageOnly(String name);
  Future<UnpubPackage?> queryPackageVersion(String name, String version);

  Future<void> addVersion(String name, UnpubVersion version);

  Future<void> addUploader(String name, String email);

  Future<void> removeUploader(String name, String email);

  void increaseDownloads(String name, String version);

  Future<UnpubQueryResult> queryPackages({
    required int size,
    required int page,
    required String sort,
    String? keyword,
    String? uploader,
    String? dependency,
    bool fetchDeps = true,
  });

  Future<void> index();
  Future<void> migrateVersions();
}
