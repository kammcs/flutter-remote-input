// The host's WebSocket server: dart:io on desktop, and a stub on the web,
// where a page can't listen for connections (and can't be controlled anyway).
// The conditional export keeps dart:io out of web builds.
export 'host_server_stub.dart' if (dart.library.io) 'host_server_io.dart';
export 'pairing_request.dart';
