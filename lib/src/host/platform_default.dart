// The host platform for this process: Windows or macOS through dart:ffi, and
// nothing elsewhere. A conditional export keeps dart:ffi out of web builds.
export 'platform_stub.dart' if (dart.library.ffi) 'platform_ffi.dart';
