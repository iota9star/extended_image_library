import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui show Codec;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:http_client_helper/http_client_helper.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';

import 'extended_image_provider.dart';
import 'extended_network_image_provider.dart' as image_provider;
import 'platform.dart';

class ExtendedNetworkImageProvider
    extends ImageProvider<image_provider.ExtendedNetworkImageProvider>
    with ExtendedImageProvider<image_provider.ExtendedNetworkImageProvider>
    implements image_provider.ExtendedNetworkImageProvider {
  /// Creates an object that fetches the image at the given URL.
  ///
  /// The arguments must not be null.
  ExtendedNetworkImageProvider(
    this.url, {
    this.scale = 1.0,
    this.headers,
    this.cache = false,
    this.retries = 3,
    this.timeLimit,
    this.timeRetry = const Duration(milliseconds: 100),
    this.cacheKey,
    this.printError = true,
    this.cacheRawData = false,
    this.cancelToken,
    this.imageCacheName,
    this.cacheMaxAge,
  });

  static final Map<String, String> _lockCache = <String, String>{};

  /// The name of [ImageCache], you can define custom [ImageCache] to store this provider.
  @override
  final String? imageCacheName;

  /// Whether cache raw data if you need to get raw data directly.
  /// For example, we need raw image data to edit,
  /// but [ui.Image.toByteData()] is very slow. So we cache the image
  /// data here.
  @override
  final bool cacheRawData;

  /// The time limit to request image
  @override
  final Duration? timeLimit;

  /// The time to retry to request
  @override
  final int retries;

  /// The time duration to retry to request
  @override
  final Duration timeRetry;

  /// Whether cache image to local
  @override
  final bool cache;

  /// The URL from which the image will be fetched.
  @override
  final String url;

  /// The scale to place in the [ImageInfo] object of the image.
  @override
  final double scale;

  /// The HTTP headers that will be used with [HttpClient.get] to fetch image from network.
  @override
  final Map<String, String>? headers;

  /// The token to cancel network request
  @override
  final CancellationToken? cancelToken;

  /// Custom cache key
  @override
  final String? cacheKey;

  /// print error
  @override
  final bool printError;

  /// The max duration to cache image.
  /// After this time the cache is expired and the image is reloaded.
  @override
  final Duration? cacheMaxAge;

  @override
  ImageStreamCompleter load(
      image_provider.ExtendedNetworkImageProvider key, DecoderCallback decode) {
    // Ownership of this controller is handed off to [_loadAsync]; it is that
    // method's responsibility to close the controller's stream when the image
    // has been loaded or an error is thrown.
    final StreamController<ImageChunkEvent> chunkEvents =
        StreamController<ImageChunkEvent>();

    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(
        key as ExtendedNetworkImageProvider,
        chunkEvents,
        decode,
      ),
      scale: key.scale,
      chunkEvents: chunkEvents.stream,
      informationCollector: () {
        return <DiagnosticsNode>[
          DiagnosticsProperty<ImageProvider>('Image provider', this),
          DiagnosticsProperty<image_provider.ExtendedNetworkImageProvider>(
              'Image key', key),
        ];
      },
    );
  }

  @override
  Future<ExtendedNetworkImageProvider> obtainKey(
      ImageConfiguration configuration) {
    return SynchronousFuture<ExtendedNetworkImageProvider>(this);
  }

  @override
  Future<bool> evict({
    ImageCache? cache,
    ImageConfiguration configuration = ImageConfiguration.empty,
    bool includeLive = true,
  }) async {
    rawImageDataMap.remove(this);
    cache ??= this.imageCache;
    final ExtendedNetworkImageProvider key = await obtainKey(configuration);
    _lockCache.remove(key.url);
    return cache.evict(key, includeLive: includeLive);
  }

  Future<ui.Codec> _loadAsync(
    ExtendedNetworkImageProvider key,
    StreamController<ImageChunkEvent> chunkEvents,
    DecoderCallback decode,
  ) async {
    assert(key == this);
    final Uint8List? uint8list = await _(key.url, chunkEvents);
    if (uint8list == null) {
      return Future<ui.Codec>.error(StateError('Failed to load $url.'));
    }
    try {
      return await instantiateImageCodec(uint8list, decode);
    } catch (e) {
      if (printError) {
        print(e);
      }
      return Future<ui.Codec>.error(StateError('Failed to load $url.'));
    }
  }

  @override
  bool operator ==(dynamic other) {
    if (other.runtimeType != runtimeType) {
      return false;
    }
    return other is ExtendedNetworkImageProvider &&
        url == other.url &&
        scale == other.scale &&
        cacheRawData == other.cacheRawData &&
        timeLimit == other.timeLimit &&
        cancelToken == other.cancelToken &&
        timeRetry == other.timeRetry &&
        cache == other.cache &&
        cacheKey == other.cacheKey &&
        headers == other.headers &&
        retries == other.retries &&
        imageCacheName == other.imageCacheName;
  }

  @override
  int get hashCode => hashValues(
        url,
        scale,
        cacheRawData,
        timeLimit,
        cancelToken,
        timeRetry,
        cache,
        cacheKey,
        headers,
        retries,
        imageCacheName,
      );

  @override
  String toString() => '$runtimeType("$url", scale: $scale)';

  /// Get network image data from cached
  @override
  Future<Uint8List?> getNetworkImageData({
    StreamController<ImageChunkEvent>? chunkEvents,
  }) async {
    return await _(url, chunkEvents);
  }

  Future<Directory> _getCacheDir() async {
    final Directory dir = Directory(
        join((await getTemporaryDirectory()).path, cacheImageFolderName));
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  File _childFile(Directory parentDir, String fileName) {
    return File(join(parentDir.path, fileName));
  }

  Future<Uint8List?> _(
    String url,
    StreamController<ImageChunkEvent>? chunkEvents,
  ) async {
    final Uri uri = Uri.parse(url);
    // create req
    final HttpClientResponse? checkResp = await _retryRequest(uri);

    final String rawFileKey = cacheKey ?? keyToMd5(url);
    final Directory parentDir = await _getCacheDir();
    final File rawFile = _childFile(parentDir, rawFileKey);

    if (checkResp == null || checkResp.statusCode != HttpStatus.ok) {
      // if request error, use cache.
      if (cache && rawFile.existsSync()) {
        return await rawFile.readAsBytes();
      }
      return null;
    }

    if (!cache) {
      return await _rw(checkResp, chunkEvents, null);
    }

    bool isExpired = false;
    final String? cacheControl =
        checkResp.headers.value(HttpHeaders.cacheControlHeader);
    if (cacheControl != null) {
      if (cacheControl.contains('no-store')) {
        // no cache, download now.
        return await _rw(checkResp, chunkEvents, null);
      } else {
        String maxAgeKey = 'max-age';
        if (cacheControl.contains(maxAgeKey)) {
          // if exist s-maxage, override max-age, use cdn max-age
          if (cacheControl.contains('s-maxage')) {
            maxAgeKey = 's-maxage';
          }
          final String maxAgeStr = cacheControl
              .split(' ')
              .firstWhere((String str) => str.contains(maxAgeKey))
              .split('=')[1]
              .trim();
          final String seconds = RegExp(r'\d+').stringMatch(maxAgeStr)!;
          final int maxAge = int.parse(seconds) * 1000;
          final String newFlag =
              '${checkResp.headers.value(HttpHeaders.etagHeader).toString()}_${checkResp.headers.value(HttpHeaders.lastModifiedHeader).toString()}';
          final File lockFile = _childFile(parentDir, '$rawFileKey.lock');
          String? lockStr = _lockCache[url];
          if (lockStr == null) {
            // never empty or blank.
            if (lockFile.existsSync()) {
              lockStr = await lockFile.readAsString();
            } else {
              await lockFile.create();
            }
          }
          final int millis = DateTime.now().millisecondsSinceEpoch;
          if (lockStr != null) {
            //never empty or blank
            final List<String> split = lockStr.split('@');
            final String flag = split[1];
            final int lastReqAt = int.parse(split[0]);
            if (flag != newFlag || lastReqAt + maxAge < millis) {
              isExpired = true;
            }
          }
          final String newLockStr = <dynamic>[millis, newFlag].join('@');
          _lockCache[url] = newLockStr;
          // we don't care lock str already written in file.
          lockFile.writeAsString(newLockStr);
        }
      }
    }
    if (!isExpired) {
      // if not expired and exist file, just return.
      if (rawFile.existsSync()) {
        if (cacheMaxAge != null) {
          final FileStat fs = rawFile.statSync();
          if (DateTime.now().subtract(cacheMaxAge!).isBefore(fs.changed)) {
            return await rawFile.readAsBytes();
          }
        } else {
          return await rawFile.readAsBytes();
        }
      }
    }

    final bool breakpointTransmission =
        checkResp.headers.value(HttpHeaders.acceptRangesHeader) == 'bytes' &&
            checkResp.contentLength > 0;
    final File tempFile = _childFile(parentDir, '$rawFileKey.temp');
    Uint8List? bytes;
    // if not expired && is support breakpoint transmission && temp file exists
    if (!isExpired && breakpointTransmission && tempFile.existsSync()) {
      final int length = await tempFile.length();
      final HttpClientResponse? resp =
          await _retryRequest(uri, callRequest: (HttpClientRequest req) {
        req.headers.add(HttpHeaders.rangeHeader, 'bytes=$length-');
        final String? flag = checkResp.headers.value(HttpHeaders.etagHeader) ??
            checkResp.headers.value(HttpHeaders.lastModifiedHeader);
        if (flag != null) {
          req.headers.add(HttpHeaders.ifRangeHeader, flag);
        }
      });
      if (resp == null) {
        return null;
      }
      if (resp.statusCode == HttpStatus.partialContent) {
        // is ok, continue download.
        bytes = await _rw(
          resp,
          chunkEvents,
          tempFile,
          loaded: length,
          fileMode: FileMode.append,
        );
      } else if (resp.statusCode == HttpStatus.requestedRangeNotSatisfiable) {
        // 416 Requested Range Not Satisfiable
        bytes = await _rw(checkResp, chunkEvents, tempFile);
      } else if (resp.statusCode == HttpStatus.ok) {
        bytes = await _rw(resp, chunkEvents, tempFile);
      } else {
        // request error.
        return null;
      }
    } else {
      bytes = await _rw(checkResp, chunkEvents, tempFile);
    }
    await tempFile.rename(rawFile.path);
    return bytes;
  }

  Future<Uint8List> _rw(
    HttpClientResponse response,
    StreamController<ImageChunkEvent>? chunkEvents,
    File? file, {
    int loaded = 0,
    FileMode fileMode = FileMode.write,
  }) async {
    final Uint8List bytes = await consolidateHttpClientResponseBytes(
      response,
      onBytesReceived: chunkEvents != null
          ? (int cumulative, int? total) {
              chunkEvents.add(ImageChunkEvent(
                cumulativeBytesLoaded: cumulative + loaded,
                expectedTotalBytes: total == null ? null : total + loaded,
              ));
            }
          : null,
    );
    await file?.writeAsBytes(bytes, mode: fileMode);
    return bytes;
  }

  Future<HttpClientResponse> _createNewRequest(
    Uri uri, {
    _CallRequest? callRequest,
  }) async {
    final HttpClientRequest request = await httpClient.getUrl(uri);
    headers?.forEach((String key, Object value) {
      request.headers.add(key, value);
    });
    callRequest?.call(request);
    final HttpClientResponse response = await request.close();
    if (timeLimit != null) {
      response.timeout(
        timeLimit!,
      );
    }
    return response;
  }

  Future<HttpClientResponse?> _retryRequest(
    Uri uri, {
    _CallRequest? callRequest,
  }) async {
    cancelToken?.throwIfCancellationRequested();
    return await RetryHelper.tryRun<HttpClientResponse>(
      () {
        return CancellationTokenSource.register(
          cancelToken,
          _createNewRequest(uri, callRequest: callRequest),
        );
      },
      cancelToken: cancelToken,
      timeRetry: timeRetry,
      retries: retries,
    );
  }

  // Do not access this field directly; use [_httpClient] instead.
  // We set `autoUncompress` to false to ensure that we can trust the value of
  // the `Content-Length` HTTP header. We automatically uncompress the content
  // in our call to [consolidateHttpClientResponseBytes].
  static final HttpClient _sharedHttpClient = HttpClient()
    ..autoUncompress = false;

  static HttpClient get httpClient {
    HttpClient client = _sharedHttpClient;
    assert(() {
      if (debugNetworkImageHttpClientProvider != null) {
        client = debugNetworkImageHttpClientProvider!();
      }
      return true;
    }());
    return client;
  }
}

typedef _CallRequest = void Function(HttpClientRequest request);
