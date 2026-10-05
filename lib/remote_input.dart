/// Remote keyboard and mouse control for Flutter desktop apps.
///
/// **Pre-release scaffold (milestone M0).** Nothing is implemented yet. The
/// design is in `docs/design.md` and the build order in `docs/roadmap.md`,
/// in the repository: <https://github.com/kammcs/flutter-remote-input>.
library;

/// The version of the wire protocol this package speaks
/// (`docs/design.md` §5). A host and a viewer agree on it in their
/// handshake.
const int remoteInputProtocolVersion = 1;
