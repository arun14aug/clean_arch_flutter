import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

/// The `ApiClient` class in Dart is a singleton class that provides a Dio instance for making API
/// requests with optional logging in debug mode.
class ApiClient {
  static final ApiClient _converter = ApiClient._internal();

  static const String kRequiredHeader = 'Header';
  static const String kAuthorization = 'Authorization';

  factory ApiClient() {
    return _converter;
  }

  ApiClient._internal();

  Dio dio() {
    var dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(milliseconds: 10000),
        receiveTimeout: const Duration(milliseconds: 10000),
      ),
    );

    if (kDebugMode) {
      dio.interceptors.add(LogInterceptor(
        error: true,
        requestHeader: true,
        requestBody: true,
        responseBody: true,
      ));
    }
    return dio;
  }
}
