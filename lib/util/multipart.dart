/// ! Source: https://github.com/simolus3/goodies.dart/blob/main/shelf_multipart/lib/multipart.dart (modified)
///
/// Copyright 2021 Simon Bidner
///
/// Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
///
/// The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
///
/// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
///
/// Support for handling multipart requests in a dart:io server
///
/// The [ReadMultipartRequest] extensions can be used to check whether a request
/// is a multipart request and to extract the individual parts.
library shelf_multipart;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http_parser/http_parser.dart';
import 'package:mime/mime.dart';
import 'package:string_scanner/string_scanner.dart';
// import 'package:shelf/shelf.dart';

/// Extension methods to handle multipart requests.
///
/// To check whether a request contains multipart data, use [isMultipart].
/// Individual parts can the be red with [parts].
extension ReadMultipartRequest on HttpRequest {
  /// Whether this request has a multipart body.
  ///
  /// Requests are considered to have a multipart body if they have a
  /// `Content-Type` header with a `multipart` type and a valid `boundary`
  /// parameter as defined by section 5.1.1 of RFC 2046.
  bool get isMultipart => _extractMultipartBoundary() != null;

  /// Reads parts of this multipart request.
  ///
  /// Each part is represented as a [MimeMultipart], which implements the
  /// [Stream] interface to emit chunks of data.
  /// Headers of a part are available through [MimeMultipart.headers].
  ///
  /// Parts can be processed by listening to this stream, as shown in this
  /// example:
  ///
  /// ```dart
  /// await for (final part in request.parts) {
  ///   final headers = part.headers;
  ///   final content = utf8.decoder.bind(part).first;
  /// }
  /// ```
  ///
  /// Listening to this stream will [read] this request, which may only be done
  /// once.
  ///
  /// Throws a [StateError] if this is not a multipart request (as reported
  /// through [isMultipart]). The stream will emit a [MimeMultipartException]
  /// if the request does not contain a well-formed multipart body.
  Stream<Multipart> get parts {
    final boundary = _extractMultipartBoundary();
    if (boundary == null) {
      throw StateError('Not a multipart request.');
    }

    return MimeMultipartTransformer(boundary)
        .bind(this)
        .map((part) => Multipart(this, part));
  }

  /// Extracts the `boundary` parameter from the content-type header, if this is
  /// a multipart request.
  String? _extractMultipartBoundary() {
    if (headers.value('Content-Type') == null) return null;

    final contentType = MediaType.parse(headers.value('Content-Type')!);
    if (contentType.type != 'multipart') return null;

    return contentType.parameters['boundary'];
  }
}

/// An entry in a multipart request.
class Multipart extends MimeMultipart {
  final HttpRequest _originalRequest;
  final MimeMultipart _inner;

  @override
  final Map<String, String> headers;

  late final MediaType? _contentType = _parseContentType();

  Encoding? get _encoding {
    var contentType = _contentType;
    if (contentType == null) return null;
    if (!contentType.parameters.containsKey('charset')) return null;
    return Encoding.getByName(contentType.parameters['charset']);
  }

  Multipart(this._originalRequest, this._inner)
      : headers = CaseInsensitiveMap.from(_inner.headers);

  MediaType? _parseContentType() {
    final value = headers['content-type'];
    if (value == null) return null;

    return MediaType.parse(value);
  }

  /// Reads the content of this subpart as a single [Uint8List].
  Future<Uint8List> readBytes() async {
    final builder = BytesBuilder();
    await forEach(builder.add);
    return builder.takeBytes();
  }

  /// Reads the content of this subpart as a string.
  ///
  /// The optional [encoding] parameter can be used to override the encoding
  /// used. By default, the `content-type` header of this part will be used,
  /// with a fallback to the `content-type` of the surrounding request and
  /// another fallback to [utf8] if everything else fails.
  Future<String> readString([Encoding? encoding]) {
    encoding ??= _encoding /* ?? _originalRequest.encoding */ ?? utf8;
    return encoding.decodeStream(this);
  }

  @override
  StreamSubscription<List<int>> listen(void Function(List<int> data)? onData,
      {void Function()? onDone, Function? onError, bool? cancelOnError}) {
    return _inner.listen(onData,
        onDone: onDone, onError: onError, cancelOnError: cancelOnError);
  }
}

extension ReadFormData on HttpRequest {
  /// Whether this request has a multipart form body.
  bool get isMultipartForm {
    final rawContentType = headers.value('Content-Type');
    if (rawContentType == null) return false;

    final type = MediaType.parse(rawContentType);
    return type.type == 'multipart' && type.subtype == 'form-data';
  }

  /// Reads invididual form data elements from this request.
  Stream<FormData> get multipartFormData {
    return parts
        .map<FormData?>((part) {
          final rawDisposition = part.headers['content-disposition'];
          if (rawDisposition == null) return null;

          final formDataParams =
              _parseFormDataContentDisposition(rawDisposition);
          if (formDataParams == null) return null;

          final name = formDataParams['name'];
          if (name == null) return null;

          return FormData._(name, formDataParams['filename'], part);
        })
        .where((data) => data != null)
        .cast();
  }
}

/// A [Multipart] subpart with a parsed [name] and [filename] values read from
/// its `content-disposition` header.
class FormData {
  /// The name of this form data element.
  ///
  /// Names are usually unique, but this is not verified by this package.
  final String name;

  /// An optional name describing the name of the file being uploaded.
  final String? filename;

  final Multipart part;

  FormData._(this.name, this.filename, this.part);
}

final _token = RegExp(r'[^()<>@,;:"\\/[\]?={} \t\x00-\x1F\x7F]+');
final _whitespace = RegExp(r'(?:(?:\r\n)?[ \t]+)*');
final _quotedString = RegExp(r'"(?:[^"\x00-\x1F\x7F]|\\.)*"');
final _quotedPair = RegExp(r'\\(.)');

/// Parses a `content-disposition: form-data; arg1="val1"; ...` header.
Map<String, String>? _parseFormDataContentDisposition(String header) {
  final scanner = StringScanner(header);

  scanner
    ..scan(_whitespace)
    ..expect(_token);
  if (scanner.lastMatch![0] != 'form-data') return null;

  final params = <String, String>{};

  while (scanner.scan(';')) {
    scanner
      ..scan(_whitespace)
      ..scan(_token);
    final key = scanner.lastMatch![0]!;
    scanner.expect('=');

    String value;
    if (scanner.scan(_token)) {
      value = scanner.lastMatch![0]!;
    } else {
      scanner.expect(_quotedString, name: 'quoted string');
      final string = scanner.lastMatch![0]!;

      value = string
          .substring(1, string.length - 1)
          .replaceAllMapped(_quotedPair, (match) => match[1]!);
    }

    scanner.scan(_whitespace);
    params[key] = value;
  }

  scanner.expectDone();
  return params;
}
