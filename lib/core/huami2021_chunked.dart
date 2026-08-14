// Derived from Gadgetbridge — `Huami2021ChunkedEncoder.java`,
// `Huami2021ChunkedDecoder.java` and `CheckSums.java`
//   Copyright (C) 2022-2024 Andreas Shimokawa and the Gadgetbridge contributors
//   https://codeberg.org/Freeyourgadget/Gadgetbridge
//
// This file is a translation of that work into Dart and is therefore a
// derivative of it. Licensed under the GNU Affero General Public License
// version 3 or later, the same terms as the original. See LICENSE.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:typed_data';
import 'encryption.dart';

/// Standard IEEE CRC-32 (matches java.util.zip.CRC32, used by Gadgetbridge's
/// CheckSums.getCRC32). Returned as an unsigned 32-bit value.
int crc32(List<int> data, [int offset = 0, int? length]) {
  length ??= data.length - offset;
  int crc = 0xffffffff;
  for (int i = 0; i < length; i++) {
    crc ^= data[offset + i] & 0xff;
    for (int j = 0; j < 8; j++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xedb88320 : (crc >> 1);
    }
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}

/// Port of Gadgetbridge's `Huami2021ChunkedEncoder` — frames payloads for the
/// Mi Band 6 chunked-transfer-2021 write characteristic (fee0/0x0016).
///
/// Frame (extended/2021): `03 | flags | 00 | handle | count` then, on the first
/// chunk, `len(4 LE) | type(2 LE) | payload`. flags: 0x01 first, 0x02 last,
/// 0x04 needs-ack, 0x08 encrypted.
class Huami2021ChunkedEncoder {
  int _writeHandle = 0;
  int _encryptedSequenceNr = 0;
  Uint8List? _sharedSessionKey;
  int _mtu;

  Huami2021ChunkedEncoder(this._mtu);

  void setMtu(int mtu) => _mtu = mtu;

  void setEncryptionParameters(int encryptedSequenceNr, Uint8List sharedSessionKey) {
    _encryptedSequenceNr = encryptedSequenceNr;
    _sharedSessionKey = sharedSessionKey;
  }

  void reset() {
    _writeHandle = 0;
    _encryptedSequenceNr = 0;
  }

  // ATT write payload budget (Gadgetbridge calcMaxWriteChunk = mtu - 3).
  int get _maxWriteChunk => _mtu - 3;

  /// Encode [data] for endpoint [type] and emit each chunk via [chunkWriter].
  void write(void Function(Uint8List chunk) chunkWriter, int type, Uint8List data,
      bool extendedFlags, bool encrypt) {
    final key = _sharedSessionKey;
    if (encrypt && key == null) {
      throw StateError("Can't encrypt without the shared session key");
    }

    _writeHandle = (_writeHandle + 1) & 0xff;
    final length = data.length;
    int remaining = length;
    int count = 0;
    int headerSize = extendedFlags ? 11 : 10;

    Uint8List dataToSend;
    if (extendedFlags && encrypt) {
      final messageKey = Uint8List(16);
      for (int i = 0; i < 16; i++) {
        messageKey[i] = (key![i] ^ _writeHandle) & 0xff;
      }
      int encryptedLength = length + 8;
      final overflow = encryptedLength % 16;
      if (overflow > 0) encryptedLength += (16 - overflow);

      final payload = Uint8List(encryptedLength);
      payload.setRange(0, length, data);
      payload[length] = _encryptedSequenceNr & 0xff;
      payload[length + 1] = (_encryptedSequenceNr >> 8) & 0xff;
      payload[length + 2] = (_encryptedSequenceNr >> 16) & 0xff;
      payload[length + 3] = (_encryptedSequenceNr >> 24) & 0xff;
      _encryptedSequenceNr++;
      final checksum = crc32(payload, 0, length + 4);
      payload[length + 4] = checksum & 0xff;
      payload[length + 5] = (checksum >> 8) & 0xff;
      payload[length + 6] = (checksum >> 16) & 0xff;
      payload[length + 7] = (checksum >> 24) & 0xff;
      remaining = encryptedLength;
      dataToSend = BLEEncryption.encryptAESECB(messageKey, payload);
    } else {
      dataToSend = data;
    }

    while (remaining > 0) {
      final maxChunkLength = _maxWriteChunk - headerSize;
      final copyBytes = remaining < maxChunkLength ? remaining : maxChunkLength;
      final chunk = Uint8List(copyBytes + headerSize);

      int flags = 0;
      if (encrypt) flags |= 0x08;
      if (count == 0) {
        flags |= 0x01; // first chunk
        int i = extendedFlags ? 5 : 4;
        chunk[i++] = length & 0xff;
        chunk[i++] = (length >> 8) & 0xff;
        chunk[i++] = (length >> 16) & 0xff;
        chunk[i++] = (length >> 24) & 0xff;
        chunk[i++] = type & 0xff;
        chunk[i] = (type >> 8) & 0xff;
      }
      if (remaining <= maxChunkLength) {
        flags |= 0x02; // last chunk
        flags |= 0x04; // needs ack
      }
      chunk[0] = 0x03;
      chunk[1] = flags;
      if (extendedFlags) {
        chunk[2] = 0;
        chunk[3] = _writeHandle;
        chunk[4] = count;
      } else {
        chunk[2] = _writeHandle;
        chunk[3] = count;
      }

      chunk.setRange(
          headerSize, headerSize + copyBytes, dataToSend, dataToSend.length - remaining);
      chunkWriter(chunk);
      remaining -= copyBytes;
      headerSize = extendedFlags ? 5 : 4;
      count++;
    }
  }
}

/// Port of Gadgetbridge's `Huami2021ChunkedDecoder` — reassembles + decrypts
/// notifications from the chunked-transfer-2021 read characteristic
/// (fee0/0x0017) and dispatches complete payloads by endpoint type.
class Huami2021ChunkedDecoder {
  final bool force2021Protocol;
  void Function(int type, Uint8List payload) onPayload;

  Huami2021ChunkedDecoder(this.onPayload, {this.force2021Protocol = true});

  int? _currentHandle;
  int _currentType = 0;
  int _currentLength = 0;
  BytesBuilder? _reassembly;
  int _expectedTotal = 0;

  int lastHandle = 0;
  int lastCount = 0;

  Uint8List? _sharedSessionKey;

  void setEncryptionParameters(Uint8List sharedSessionKey) {
    _sharedSessionKey = sharedSessionKey;
  }

  void reset() {
    _currentHandle = null;
    _currentType = 0;
    _reassembly = null;
  }

  /// Decode one notification frame. Returns true if the band expects an ack.
  bool decode(Uint8List data) {
    int i = 0;
    if (data[i++] != 0x03) return false; // not chunked
    final flags = data[i++];
    final encrypted = (flags & 0x08) == 0x08;
    final firstChunk = (flags & 0x01) == 0x01;
    final lastChunk = (flags & 0x02) == 0x02;
    final needsAck = (flags & 0x04) == 0x04;

    if (force2021Protocol) i++; // skip extended header (the 0x00)
    final handle = data[i++];
    if (_currentHandle != null && _currentHandle != handle) {
      return false; // ignore unexpected handle
    }
    lastHandle = handle;
    lastCount = data[i++];

    if (firstChunk) {
      int fullLength = (data[i++] & 0xff) |
          ((data[i++] & 0xff) << 8) |
          ((data[i++] & 0xff) << 16) |
          ((data[i++] & 0xff) << 24);
      _currentLength = fullLength;
      if (encrypted) {
        int encryptedLength = fullLength + 8;
        final overflow = encryptedLength % 16;
        if (overflow > 0) encryptedLength += (16 - overflow);
        fullLength = encryptedLength;
      }
      _expectedTotal = fullLength;
      _reassembly = BytesBuilder();
      _currentType = (data[i++] & 0xff) | ((data[i++] & 0xff) << 8);
      _currentHandle = handle;
    }

    final buf = _reassembly;
    if (buf == null) return needsAck; // stray continuation
    buf.add(Uint8List.sublistView(data, i));

    if (lastChunk) {
      var payload = buf.toBytes();
      // Guard against over/under-read; GB allocates exactly _expectedTotal.
      if (payload.length > _expectedTotal) {
        payload = Uint8List.sublistView(payload, 0, _expectedTotal);
      }
      if (encrypted) {
        final key = _sharedSessionKey;
        if (key == null) {
          reset();
          return false;
        }
        final messageKey = Uint8List(16);
        for (int j = 0; j < 16; j++) {
          messageKey[j] = (key[j] ^ handle) & 0xff;
        }
        try {
          final dec = BLEEncryption.decryptAESECB(messageKey, payload);
          payload = Uint8List.sublistView(dec, 0, _currentLength);
        } catch (_) {
          reset();
          return false;
        }
      }
      try {
        onPayload(_currentType, payload);
      } catch (_) {}
      reset();
    }
    return needsAck;
  }
}
