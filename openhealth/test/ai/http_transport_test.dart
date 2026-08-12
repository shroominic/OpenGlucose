import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cgm_core/cgm_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/ai/http_transport.dart';

class _FakeHeaders implements HttpHeaders {
  final Map<String, String> values = <String, String>{};

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name.toLowerCase()] = '$value';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeRequest implements HttpClientRequest {
  _FakeRequest(this._response);

  final HttpClientResponse _response;
  final BytesBuilder body = BytesBuilder();
  final _FakeHeaders fakeHeaders = _FakeHeaders();
  bool _followRedirects = true;

  @override
  HttpHeaders get headers => fakeHeaders;

  @override
  bool get followRedirects => _followRedirects;

  @override
  set followRedirects(bool value) => _followRedirects = value;

  @override
  void add(List<int> data) => body.add(data);

  @override
  Future<HttpClientResponse> close() async => _response;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeResponse extends Stream<List<int>> implements HttpClientResponse {
  _FakeResponse({required this.statusCode, required String body})
    : _body = utf8.encode(body);

  @override
  final int statusCode;
  final List<int> _body;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(_body).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeClient implements HttpClient {
  _FakeClient({required int statusCode, required String responseBody})
    : _response = _FakeResponse(
        statusCode: statusCode,
        body: responseBody,
      );

  final HttpClientResponse _response;
  final List<Uri> postedUris = <Uri>[];
  _FakeRequest? lastRequest;

  @override
  Duration? connectionTimeout;

  @override
  Future<HttpClientRequest> postUrl(Uri url) async {
    postedUris.add(url);
    return lastRequest = _FakeRequest(_response);
  }

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _request = AiRequest(
  messages: <AiMessage>[AiMessage.user('private glucose summary')],
);

AiProviderConfig _config(String baseUrl) => AiProviderConfig(
  baseUrl: baseUrl,
  apiKey: 'sk-private',
);

Future<String> _sendWithClient(
  _FakeClient client,
  AiProviderConfig config,
) => HttpOverrides.runZoned(
  () => HttpAiTransport().call(_request, config),
  createHttpClient: (_) => client,
);

void main() {
  test(
    'rejects endpoints that could expose credentials or cleartext data',
    () async {
      const invalidBaseUrls = <String>[
        'http://api.example.com/v1',
        'api.example.com/v1',
        'https:///v1',
        'https://user:password@api.example.com/v1',
        'https://api.example.com/v1?redirect=evil',
        'https://api.example.com/v1#fragment',
      ];

      for (final baseUrl in invalidBaseUrls) {
        final client = _FakeClient(statusCode: 200, responseBody: '{}');
        await expectLater(
          _sendWithClient(client, _config(baseUrl)),
          throwsA(
            isA<AiGenerationException>().having(
              (error) => error.message,
              'message',
              contains('absolute HTTPS URL'),
            ),
          ),
          reason: baseUrl,
        );
        expect(client.postedUris, isEmpty, reason: baseUrl);
      }
    },
  );

  test('posts only to the resolved HTTPS endpoint without redirects', () async {
    final client = _FakeClient(
      statusCode: 200,
      responseBody: '{"choices":[{"message":{"content":"safe response"}}]}',
    );

    final result = await _sendWithClient(
      client,
      _config('https://api.example.com/v1/'),
    );

    expect(result, 'safe response');
    expect(
      client.postedUris,
      <Uri>[Uri.parse('https://api.example.com/v1/chat/completions')],
    );
    final request = client.lastRequest!;
    expect(request.followRedirects, isFalse);
    expect(
      request.fakeHeaders.values[HttpHeaders.authorizationHeader],
      'Bearer sk-private',
    );
    expect(utf8.decode(request.body.takeBytes()), contains('private glucose'));
  });

  test('a redirect response is a hard failure and is never followed', () async {
    final client = _FakeClient(
      statusCode: HttpStatus.found,
      responseBody: '{"choices":[{"message":{"content":"do not accept"}}]}',
    );

    await expectLater(
      _sendWithClient(client, _config('https://api.example.com/v1')),
      throwsA(
        isA<AiGenerationException>().having(
          (error) => error.message,
          'message',
          'Provider returned HTTP 302.',
        ),
      ),
    );

    expect(client.postedUris, hasLength(1));
    expect(client.lastRequest!.followRedirects, isFalse);
  });
}
