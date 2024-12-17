import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:collection/collection.dart' show IterableExtension;
import 'package:googleapis/oauth2/v2.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:pub_semver/pub_semver.dart' as semver;
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_cors_headers/shelf_cors_headers.dart';
import 'package:shelf_multipart/form_data.dart';
import 'package:shelf_multipart/multipart.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:unpub/src/meta_store.dart';
import 'package:unpub/src/models.dart';
import 'package:unpub/src/package_store.dart';
import 'package:unpub/unpub_api/lib/models.dart';

import 'static/index.html.dart' as index_html;
import 'static/main.dart.js.dart' as main_dart_js;
import 'utils.dart';

part 'app.g.dart';

class App {
  static const proxyOriginHeader = "proxy-origin";

  /// meta information store
  final MetaStore metaStore;

  /// package(tarball) store
  final PackageStore packageStore;

  /// upstream url, default: https://pub.dev
  final String upstream;

  /// http(s) proxy to call googleapis (to get uploader email)
  final String? googleapisProxy;
  final String? overrideUploaderEmail;

  /// A forward proxy uri
  final Uri? proxy_origin;

  /// validate if the package can be published
  ///
  /// for more details, see: https://github.com/bytedance/unpub#package-validator
  final Future<void> Function(
      Map<String, dynamic> pubspec, String uploaderEmail)? uploadValidator;

  App({
    required this.metaStore,
    required this.packageStore,
    this.upstream = 'https://pub.dev',
    this.googleapisProxy,
    this.overrideUploaderEmail,
    this.uploadValidator,
    this.proxy_origin,
  });

  static shelf.Response _okWithJson(Map<String, dynamic> data) =>
      shelf.Response.ok(
        json.encode(data),
        headers: {
          HttpHeaders.contentTypeHeader: ContentType.json.mimeType,
          'Access-Control-Allow-Origin': '*'
        },
      );

  static shelf.Response _successMessage(String message) => _okWithJson({
        'success': {'message': message}
      });

  static shelf.Response _badRequest(String message,
          {int status = HttpStatus.badRequest}) =>
      shelf.Response(
        status,
        headers: {HttpHeaders.contentTypeHeader: ContentType.json.mimeType},
        body: json.encode({
          'error': {'message': message}
        }),
      );

  http.Client? _googleapisClient;

  String _resolveUrl(shelf.Request req, String reference) {
    if (proxy_origin != null) {
      return proxy_origin!.resolve(reference).toString();
    }
    String? proxyOriginInHeader = req.headers[proxyOriginHeader];
    if (proxyOriginInHeader != null) {
      return Uri.parse(proxyOriginInHeader).resolve(reference).toString();
    }
    return req.requestedUri.resolve(reference).toString();
  }

  Future<String> _getUploaderEmail(shelf.Request req) async {
    if (overrideUploaderEmail != null) return overrideUploaderEmail!;

    var authHeader = req.headers[HttpHeaders.authorizationHeader];
    if (authHeader == null) throw 'missing authorization header';

    var token = authHeader.split(' ').last;

    if (_googleapisClient == null) {
      if (googleapisProxy != null) {
        _googleapisClient = IOClient(HttpClient()
          ..findProxy = (url) => HttpClient.findProxyFromEnvironment(url,
              environment: {"https_proxy": googleapisProxy!}));
      } else {
        _googleapisClient = http.Client();
      }
    }

    var info =
        await Oauth2Api(_googleapisClient!).tokeninfo(accessToken: token);
    if (info.email == null) throw 'fail to get google account email';
    return info.email!;
  }

  Future<HttpServer> serve([String host = '0.0.0.0', int port = 4000]) async {
    var handler = const shelf.Pipeline()
        .addMiddleware(corsHeaders())
        .addMiddleware(shelf.logRequests())
        .addHandler(
      (req) async {
        var res = await router.call(req);
        return res;
      },
    );
    var server = await shelf_io.serve(
      handler,
      host,
      port,
      poweredByHeader: 'PUB.XETIA.DEV',
    );
    return server;
  }

  Map<String, dynamic> _versionToJson(UnpubVersion item, shelf.Request req) {
    var name = item.pubspec['name'] as String;
    var version = item.version;
    return {
      'archive_url':
          _resolveUrl(req, '/packages/$name/versions/$version.tar.gz'),
      'pubspec': item.pubspec,
      'version': version,
    };
  }

  bool isPubClient(shelf.Request req) {
    var ua = req.headers[HttpHeaders.userAgentHeader];
    print(ua);
    return ua != null && ua.toLowerCase().contains('dart pub');
  }

  Router get router => _$AppRouter(this);

  @Route.get('/packages/<name>.json')
  Future<shelf.Response> getPackageVersion(
    shelf.Request req,
    String name,
  ) async {
    var package = await metaStore.queryPackage(name);
    if (package == null) {
      return shelf.Response.notFound(null);
    }

    return _okWithJson(
      {
        'name': package.name,
        'download': package.download,
        'created_at': package.createdAt.toIso8601String(),
        'updated_at': package.updatedAt.toIso8601String(),
        'versions': [
          for (final version in package.versions) version.version,
        ],
      },
    );
  }

  @Route.post('/api/createindex')
  Future<shelf.Response> index(shelf.Request req) async {
    await metaStore.index();
    return _okWithJson({
      'success': true,
    });
  }

  @Route.post('/api/migrateversion')
  Future<shelf.Response> migrate(shelf.Request req) async {
    await metaStore.migrateVersions();
    return _okWithJson({
      'success': true,
    });
  }

  @Route.get('/api/packages/<name>')
  Future<shelf.Response> getVersions(shelf.Request req, String name) async {
    var package = await metaStore.queryPackage(name);

    if (package == null) {
      return shelf.Response.found(
          Uri.parse(upstream).resolve('/api/packages/$name').toString());
    }

    var versionMaps =
        package.versions.map((item) => _versionToJson(item, req)).toList();

    return _okWithJson({
      'name': name,
      'latest': versionMaps.last, // TODO: Exclude pre release
      'versions': versionMaps,
    });
  }

  @Route.get('/api/packages/<name>/versions/<version>')
  Future<shelf.Response> getVersion(
      shelf.Request req, String name, String version) async {
    // Important: + -> %2B, should be decoded here
    try {
      version = Uri.decodeComponent(version);
    } catch (err) {
      print(err);
    }

    var package = await metaStore.queryPackageVersion(name, version);
    if (package == null) {
      return shelf.Response.found(Uri.parse(upstream)
          .resolve('/api/packages/$name/versions/$version')
          .toString());
    }

    if (package.versions.isEmpty) {
      return shelf.Response.notFound('Not Found');
    }

    return _okWithJson(_versionToJson(package.versions.first, req));
  }

  @Route.get('/packages/<name>/versions/<version>.tar.gz')
  Future<shelf.Response> download(
      shelf.Request req, String name, String version) async {
    var package = await metaStore.queryPackageVersion(name, version);
    if (package == null) {
      return shelf.Response.found(Uri.parse(upstream)
          .resolve('/packages/$name/versions/$version.tar.gz')
          .toString());
    }

    if (isPubClient(req)) {
      metaStore.increaseDownloads(name, version);
    }

    if (packageStore.supportsDownloadUrl) {
      return shelf.Response.found(
          await packageStore.downloadUrl(name, version));
    } else {
      return shelf.Response.ok(
        packageStore.download(name, version),
        headers: {HttpHeaders.contentTypeHeader: ContentType.binary.mimeType},
      );
    }
  }

  @Route.get('/api/packages/versions/new')
  Future<shelf.Response> getUploadUrl(shelf.Request req) async {
    return _okWithJson({
      'url': _resolveUrl(req, '/api/packages/versions/newUpload').toString(),
      'fields': {},
    });
  }

  @Route.post('/api/packages/versions/newUpload')
  Future<shelf.Response> upload(shelf.Request req) async {
    try {
      var uploader = await _getUploaderEmail(req);

      if (!req.isMultipartForm) {
        throw 'invalid request content-type';
      }

      Uint8List? tarballBytes;
      ArchiveFile? pubspecArchiveFile;
      ArchiveFile? readmeFile;
      ArchiveFile? changelogFile;

      try {
        Multipart? fileData;
        // Iterate over parts making up this request:

        final parts = await req.multipartFormData.toList();
        for (final part in parts) {
          if (part.name == 'file' || part.filename == 'package.tar.gz') {
            fileData = part.part;
            break;
          }
        }

        tarballBytes = await fileData!.readBytes();
        var tarBytes = GZipDecoder().decodeBytes(tarballBytes);
        var archive = TarDecoder().decodeBytes(tarBytes);

        for (var file in archive.files) {
          if (file.name == 'pubspec.yaml') {
            pubspecArchiveFile = file;
            continue;
          }
          if (file.name.toLowerCase() == 'readme.md') {
            readmeFile = file;
            continue;
          }
          if (file.name.toLowerCase() == 'changelog.md') {
            changelogFile = file;
            continue;
          }
        }
      } catch (e) {
        throw 'failed to read packages.tar.gz';
      }

      if (pubspecArchiveFile == null) {
        throw 'Did not find any pubspec.yaml file in upload. Aborting.';
      }

      var pubspecYaml = utf8.decode(pubspecArchiveFile.content);
      var pubspec = loadYamlAsMap(pubspecYaml)!;

      if (uploadValidator != null) {
        await uploadValidator!(pubspec, uploader);
      }

      var name = pubspec['name'] as String;
      var version = pubspec['version'] as String;

      var package = await metaStore.queryPackageOnly(name);

      // Package already exists
      if (package != null) {
        if (package.private == false) {
          throw '$name is not a private package. Please upload it to https://pub.dev';
        }

        // Check uploaders
        if (package.uploaders?.contains(uploader) == false) {
          throw '$uploader is not an uploader of $name';
        }

        // Check duplicated version
        var pkg = await metaStore.queryPackageVersion(name, version);
        var duplicated = pkg != null;
        if (duplicated) {
          throw 'version invalid: $name@$version already exists.';
        }
      }

      // Upload package tarball to storage
      await packageStore.upload(name, version, tarballBytes);

      String? readme;
      String? changelog;
      if (readmeFile != null) {
        readme = utf8.decode(readmeFile.content);
      }
      if (changelogFile != null) {
        changelog = utf8.decode(changelogFile.content);
      }

      // Write package meta to database
      var unpubVersion = UnpubVersion(
        version,
        pubspec,
        pubspecYaml,
        uploader,
        readme,
        changelog,
        DateTime.now(),
      );

      await metaStore.addVersion(name, unpubVersion);

      // TODO: Upload docs
      return shelf.Response.found(
          _resolveUrl(req, '/api/packages/versions/newUploadFinish'));
    } catch (err) {
      return shelf.Response.found(_resolveUrl(
          req, '/api/packages/versions/newUploadFinish?error=$err'));
    }
  }

  @Route.get('/api/packages/versions/newUploadFinish')
  Future<shelf.Response> uploadFinish(shelf.Request req) async {
    var error = req.requestedUri.queryParameters['error'];
    if (error != null) {
      return _badRequest(error);
    }
    return _successMessage('Successfully uploaded package.');
  }

  @Route.post('/api/packages/<name>/uploaders')
  Future<shelf.Response> addUploader(shelf.Request req, String name) async {
    var body = await req.readAsString();
    var email = Uri.splitQueryString(body)['email']!; // TODO: null
    var operatorEmail = await _getUploaderEmail(req);
    var package = await metaStore.queryPackageOnly(name);

    if (package?.uploaders?.contains(operatorEmail) == false) {
      return _badRequest('no permission', status: HttpStatus.forbidden);
    }
    if (package?.uploaders?.contains(email) == true) {
      return _badRequest('email already exists');
    }

    await metaStore.addUploader(name, email);
    return _successMessage('uploader added');
  }

  @Route.delete('/api/packages/<name>/uploaders/<email>')
  Future<shelf.Response> removeUploader(
      shelf.Request req, String name, String email) async {
    email = Uri.decodeComponent(email);
    var operatorEmail = await _getUploaderEmail(req);
    var package = await metaStore.queryPackageOnly(name);

    // TODO: null
    if (package?.uploaders?.contains(operatorEmail) == false) {
      return _badRequest('no permission', status: HttpStatus.forbidden);
    }
    if (package?.uploaders?.contains(email) == false) {
      return _badRequest('email not uploader');
    }

    await metaStore.removeUploader(name, email);
    return _successMessage('uploader removed');
  }

  @Route.get('/webapi/packages')
  Future<shelf.Response> getPackages(shelf.Request req) async {
    try {
      var params = req.requestedUri.queryParameters;
      var size = int.tryParse(params['size'] ?? '') ?? 10;
      var page = int.tryParse(params['page'] ?? '') ?? 0;
      var sort = params['sort'] ?? 'download';
      var q = params['q'];

      String? keyword;
      String? uploader;
      String? dependency;

      if (q is String) {
        if (q.startsWith('email:')) {
          uploader = q.substring(6).trim();
        } else if (q.startsWith('dependency:')) {
          dependency = q.substring(11).trim();
        } else {
          keyword = q;
        }
      }

      final result = await metaStore.queryPackages(
        size: size,
        page: page,
        sort: sort,
        keyword: keyword,
        uploader: uploader,
        dependency: dependency,
        fetchDeps: false,
      );

      var data = ListApi(result.count, [
        for (var package in result.packages)
          ListApiPackage(
            package.name,
            package.lastVersion!.pubspec['description'] as String?,
            getPackageTags(package.lastVersion!.pubspec),
            package.lastVersion!.version,
            package.updatedAt,
          )
      ]);

      return _okWithJson({'data': data.toJson()});
    } catch (e) {
      return _okWithJson({'error': e.toString()});
    }
  }

  @Route.get('/packages/<name>.json')
  Future<shelf.Response> getPackageVersions(
      shelf.Request req, String name) async {
    var package = await metaStore.queryPackage(name);
    if (package == null) {
      return _badRequest('package not exists', status: HttpStatus.notFound);
    }

    var versions = package.versions.map((v) => v.version).toList();
    return _okWithJson({
      'name': name,
      'versions': versions,
    });
  }

  @Route.get('/webapi/package/<name>/<version>')
  Future<shelf.Response> getPackageDetail(
      shelf.Request req, String name, String version) async {
    var package = version == 'latest'
        ? await metaStore.queryPackage(name, versionsSortAsc: false)
        : await metaStore.queryPackageVersion(name, version);
    if (package == null) {
      return _okWithJson({'error': 'package not exists'});
    }

    UnpubVersion? packageVersion;
    if (version == 'latest') {
      packageVersion = package.lastVersion;
    } else {
      packageVersion =
          package.versions.firstWhereOrNull((item) => item.version == version);
    }
    if (packageVersion == null) {
      return _okWithJson({'error': 'version not exists'});
    }

    var versions = package.versions
        .map((v) => DetailViewVersion(v.version, v.createdAt))
        .toList();

    var pubspec = packageVersion.pubspec;
    List<String?> authors;
    if (pubspec['author'] != null) {
      authors = RegExp(r'<(.*?)>')
          .allMatches(pubspec['author'])
          .map((match) => match.group(1))
          .toList();
    } else if (pubspec['authors'] != null) {
      authors = (pubspec['authors'] as List)
          .map((author) => RegExp(r'<(.*?)>').firstMatch(author)!.group(1))
          .toList();
    } else {
      authors = [];
    }

    var depMap = (pubspec['dependencies'] as Map? ?? {}).cast<String, String>();

    var data = WebapiDetailView(
      package.name,
      packageVersion.version,
      packageVersion.pubspec['description'] ?? '',
      packageVersion.pubspec['homepage'] ?? '',
      package.uploaders ?? [],
      packageVersion.createdAt,
      packageVersion.readme,
      packageVersion.changelog,
      versions,
      authors,
      depMap.keys.toList(),
      getPackageTags(packageVersion.pubspec),
    );

    return _okWithJson({'data': data.toJson()});
  }

  @Route.get('/')
  @Route.get('/packages')
  @Route.get('/packages/<name>')
  @Route.get('/packages/<name>/versions/<version>')
  Future<shelf.Response> indexHtml(shelf.Request req) async {
    return shelf.Response.ok(index_html.content,
        headers: {HttpHeaders.contentTypeHeader: ContentType.html.mimeType});
  }

  @Route.get('/main.dart.js')
  Future<shelf.Response> mainDartJs(shelf.Request req) async {
    return shelf.Response.ok(main_dart_js.content,
        headers: {HttpHeaders.contentTypeHeader: 'text/javascript'});
  }

  String _getBadgeUrl(String label, String message, String color,
      Map<String, String> queryParameters) {
    var badgeUri = Uri.parse('https://img.shields.io/static/v1');
    return Uri(
        scheme: badgeUri.scheme,
        host: badgeUri.host,
        path: badgeUri.path,
        queryParameters: {
          'label': label,
          'message': message,
          'color': color,
          ...queryParameters,
        }).toString();
  }

  @Route.get('/badge/<type>/<name>')
  Future<shelf.Response> badge(
      shelf.Request req, String type, String name) async {
    var queryParameters = req.requestedUri.queryParameters;
    var package = await metaStore.queryPackage(name);
    if (package == null) {
      return shelf.Response.notFound('Not found');
    }

    switch (type) {
      case 'v':
        var latest = semver.Version.primary(package.versions
            .map((pv) => semver.Version.parse(pv.version))
            .toList());

        var color = latest.major == 0 ? 'orange' : 'blue';

        return shelf.Response.found(
            _getBadgeUrl('unpub', latest.toString(), color, queryParameters));
      case 'd':
        return shelf.Response.found(_getBadgeUrl(
            'downloads', package.download.toString(), 'blue', queryParameters));
      default:
        return shelf.Response.notFound('Not found');
    }
  }
}
