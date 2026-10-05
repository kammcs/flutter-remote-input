/// Serial-number arithmetic for 32-bit sequence numbers (RFC 1982), so
/// `seq` may wrap (`docs/design.md` §5.1).
library;

/// One past the largest sequence number.
const int seqModulus = 0x100000000;

/// Whether [a] comes after [b] in 32-bit serial-number order. Undefined
/// (false) when they are exactly half the space apart.
bool seqAfter(int a, int b) {
  final d = (a - b) % seqModulus;
  return d != 0 && d < 0x80000000;
}

/// The sequence number after [seq], wrapping at 2^32.
int seqNext(int seq) => (seq + 1) % seqModulus;
