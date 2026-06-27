import 'dart:convert';
import 'dart:typed_data';

/// Minimal ID3v2.3 tag writer — just enough to attach a JPEG cover image
/// (APIC) and a title (TIT2) to an MP3 so the saved file shows the photo as
/// album art in players/galleries. No external dependency.
class Id3 {
  /// Prepend an ID3v2.3 tag (title + JPEG cover) to raw [mp3] bytes.
  static Uint8List wrap(List<int> mp3, String title, List<int> jpegCover) {
    final frames = <int>[
      ..._textFrame('TIT2', title),
      ..._apicFrame(jpegCover),
    ];
    final header = <int>[
      0x49, 0x44, 0x33, // "ID3"
      0x03, 0x00, // version 2.3.0
      0x00, // flags
      ..._synchsafe(frames.length), // tag size (excludes this 10-byte header)
    ];
    final out = Uint8List(header.length + frames.length + mp3.length);
    out.setRange(0, header.length, header);
    out.setRange(header.length, header.length + frames.length, frames);
    out.setRange(header.length + frames.length, out.length, mp3);
    return out;
  }

  /// A UTF-16 text frame (encoding byte 0x01 + BOM), e.g. TIT2.
  static List<int> _textFrame(String id, String text) {
    final body = <int>[0x01, 0xFF, 0xFE, ..._utf16le(text)];
    return _frame(id, body);
  }

  /// APIC frame: cover (front) JPEG.
  static List<int> _apicFrame(List<int> jpeg) {
    final body = <int>[
      0x00, // text encoding: ISO-8859-1 (for the mime/description fields)
      ...ascii.encode('image/jpeg'), 0x00, // MIME type, null-terminated
      0x03, // picture type: cover (front)
      0x00, // empty description, null-terminated
      ...jpeg,
    ];
    return _frame('APIC', body);
  }

  /// Frame = 4-char id + 32-bit big-endian size + 2 flag bytes + body.
  static List<int> _frame(String id, List<int> body) {
    return <int>[
      ...ascii.encode(id),
      ..._uint32be(body.length),
      0x00, 0x00, // flags
      ...body,
    ];
  }

  static List<int> _utf16le(String s) {
    final out = <int>[];
    for (final u in s.codeUnits) {
      out
        ..add(u & 0xFF)
        ..add((u >> 8) & 0xFF);
    }
    out
      ..add(0x00)
      ..add(0x00); // null terminator
    return out;
  }

  static List<int> _uint32be(int v) =>
      [(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];

  /// 28-bit synchsafe integer (7 bits per byte) used for the tag size.
  static List<int> _synchsafe(int v) => [
        (v >> 21) & 0x7F,
        (v >> 14) & 0x7F,
        (v >> 7) & 0x7F,
        v & 0x7F,
      ];
}
