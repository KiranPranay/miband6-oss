// Derived from Gadgetbridge — `ECDH_B163.java`
//   Copyright (C) 2022-2024 Andreas Shimokawa and the Gadgetbridge contributors
//   https://codeberg.org/Freeyourgadget/Gadgetbridge
//
// Gadgetbridge's file is itself a port of tiny-ECDH-c (public domain,
// Kokke, https://github.com/kokke/tiny-ECDH-c).
//
// This file is a translation of that work into Dart and is therefore a
// derivative of it. Licensed under the GNU Affero General Public License
// version 3 or later, the same terms as the original. See LICENSE.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:typed_data';

/// Pure-Dart port of Gadgetbridge's `ECDH_B163` (itself a port of tiny-ECDH-c,
/// NIST B-163 curve only). Used for the Huami 2021 / Mi Band 6 "sign-key" auth.
///
/// Faithful 1:1 translation: word vectors are 32-bit, stored in [Uint32List]
/// which truncates writes to 32 bits exactly like Java's `int`. Where the Java
/// uses `& 0xffffffffL` for unsigned semantics, Dart ints are 64-bit so reading
/// a Uint32List element already yields the unsigned 0..2^32-1 value.
class EcdhB163 {
  static const int curveDegree = 163;
  static const int eccPrvKeySize = 24;
  static const int eccPubKeySize = 2 * eccPrvKeySize;

  static const int bitvecMargin = 3;
  static const int bitvecNbits = curveDegree + bitvecMargin;
  static const int bitvecNwords = (bitvecNbits + 31) ~/ 32; // 6
  static const int bitvecNbytes = 4 * bitvecNwords; // 24

  // NIST B-163 curve parameters.
  static final Uint32List _polynomial = Uint32List.fromList(
      [0x000000c9, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000008]);
  static final Uint32List _coeffB = Uint32List.fromList(
      [0x4a3205fd, 0x512f7874, 0x1481eb10, 0xb8c953ca, 0x0a601907, 0x00000002]);
  static final Uint32List _baseX = Uint32List.fromList(
      [0xe8343e36, 0xd4994637, 0xa0991168, 0x86a2d57e, 0xf0eba162, 0x00000003]);
  static final Uint32List _baseY = Uint32List.fromList(
      [0x797324f1, 0xb11c5c0c, 0xa2cdd545, 0x71a0094f, 0xd51fbc6c, 0x00000000]);
  static final Uint32List _baseOrder = Uint32List.fromList(
      [0xa4234c33, 0x77e70c12, 0x000292fe, 0x00000000, 0x00000000, 0x00000004]);

  // ---- bit-vector helpers ----------------------------------------------------

  static int _getBit(Uint32List x, int idx) =>
      ((x[idx ~/ 32] >> (idx & 31)) & 1);

  static void _clrBit(Uint32List x, int idx) {
    x[idx ~/ 32] = x[idx ~/ 32] & (~(1 << (idx & 31)) & 0xffffffff);
  }

  static void _copy(Uint32List x, Uint32List y) {
    for (int i = 0; i < bitvecNwords; ++i) {
      x[i] = y[i];
    }
  }

  static void _swap(Uint32List x, Uint32List y) {
    final tmp = Uint32List(bitvecNwords);
    _copy(tmp, x);
    _copy(x, y);
    _copy(y, tmp);
  }

  static bool _equal(Uint32List x, Uint32List y) {
    for (int i = 0; i < bitvecNwords; ++i) {
      if (x[i] != y[i]) return false;
    }
    return true;
  }

  static void _setZero(Uint32List x) {
    for (int i = 0; i < bitvecNwords; ++i) {
      x[i] = 0;
    }
  }

  static bool _isZero(Uint32List x) {
    int i = 0;
    while (i < bitvecNwords) {
      if (x[i] != 0) break;
      i += 1;
    }
    return i == bitvecNwords;
  }

  /// number of the highest one-bit + 1
  static int _degree(Uint32List x) {
    int i = bitvecNwords * 32;
    int y = bitvecNwords;
    while ((i > 0) && (x[--y] == 0)) {
      i -= 32;
    }
    if (i != 0) {
      int u32mask = 0x80000000;
      while ((x[y] & u32mask) == 0) {
        u32mask = u32mask >> 1;
        i -= 1;
      }
    }
    return i;
  }

  /// left-shift by `nbits`
  static void _lshift(Uint32List x, Uint32List y, int nbits) {
    final nwords = nbits ~/ 32;
    int i, j;
    for (i = 0; i < nwords; ++i) {
      x[i] = 0;
    }
    j = 0;
    while (i < bitvecNwords) {
      x[i] = y[j];
      i += 1;
      j += 1;
    }
    nbits &= 31;
    if (nbits != 0) {
      for (i = bitvecNwords - 1; i > 0; --i) {
        x[i] = ((x[i] << nbits) | (x[i - 1] >> (32 - nbits))) & 0xffffffff;
      }
      x[0] = (x[0] << nbits) & 0xffffffff;
    }
  }

  // ---- GF(2^m) field arithmetic ---------------------------------------------

  static void _fieldSetOne(Uint32List x) {
    x[0] = 1;
    for (int i = 1; i < bitvecNwords; ++i) {
      x[i] = 0;
    }
  }

  static bool _fieldIsOne(Uint32List x) {
    if (x[0] != 1) return false;
    int i;
    for (i = 1; i < bitvecNwords; ++i) {
      if (x[i] != 0) break;
    }
    return i == bitvecNwords;
  }

  static void _fieldAdd(Uint32List z, Uint32List x, Uint32List y) {
    for (int i = 0; i < bitvecNwords; ++i) {
      z[i] = x[i] ^ y[i];
    }
  }

  static void _fieldInc(Uint32List x) {
    x[0] ^= 1;
  }

  static void _fieldMul(Uint32List z, Uint32List x, Uint32List y) {
    final tmp = Uint32List(bitvecNwords);
    _copy(tmp, x);
    if (_getBit(y, 0) != 0) {
      _copy(z, x);
    } else {
      _setZero(z);
    }
    for (int i = 1; i < curveDegree; ++i) {
      _lshift(tmp, tmp, 1);
      if (_getBit(tmp, curveDegree) != 0) {
        _fieldAdd(tmp, tmp, _polynomial);
      }
      if (_getBit(y, i) != 0) {
        _fieldAdd(z, z, tmp);
      }
    }
  }

  static void _fieldInv(Uint32List z, Uint32List x) {
    final u = Uint32List(bitvecNwords);
    final v = Uint32List(bitvecNwords);
    final g = Uint32List(bitvecNwords);
    final h = Uint32List(bitvecNwords);
    int i;
    _copy(u, x);
    _copy(v, _polynomial);
    _setZero(g);
    _fieldSetOne(z);
    while (!_fieldIsOne(u)) {
      i = _degree(u) - _degree(v);
      if (i < 0) {
        _swap(u, v);
        _swap(g, z);
        i = -i;
      }
      _lshift(h, v, i);
      _fieldAdd(u, u, h);
      _lshift(h, g, i);
      _fieldAdd(z, z, h);
    }
  }

  // ---- curve point arithmetic ------------------------------------------------

  static void _pointCopy(
      Uint32List x1, Uint32List y1, Uint32List x2, Uint32List y2) {
    _copy(x1, x2);
    _copy(y1, y2);
  }

  static void _pointSetZero(Uint32List x, Uint32List y) {
    _setZero(x);
    _setZero(y);
  }

  static bool _pointIsZero(Uint32List x, Uint32List y) =>
      _isZero(x) && _isZero(y);

  static void _pointDouble(Uint32List x, Uint32List y) {
    if (_isZero(x)) {
      _setZero(y);
    } else {
      final l = Uint32List(bitvecNwords);
      _fieldInv(l, x);
      _fieldMul(l, l, y);
      _fieldAdd(l, l, x);
      _fieldMul(y, x, x);
      _fieldMul(x, l, l);
      _fieldInc(l);
      _fieldAdd(x, x, l);
      _fieldMul(l, l, x);
      _fieldAdd(y, y, l);
    }
  }

  static void _pointAdd(
      Uint32List x1, Uint32List y1, Uint32List x2, Uint32List y2) {
    if (!_pointIsZero(x2, y2)) {
      if (_pointIsZero(x1, y1)) {
        _pointCopy(x1, y1, x2, y2);
      } else {
        if (_equal(x1, x2)) {
          if (_equal(y1, y2)) {
            _pointDouble(x1, y1);
          } else {
            _pointSetZero(x1, y1);
          }
        } else {
          final a = Uint32List(bitvecNwords);
          final b = Uint32List(bitvecNwords);
          final c = Uint32List(bitvecNwords);
          final d = Uint32List(bitvecNwords);
          _fieldAdd(a, y1, y2);
          _fieldAdd(b, x1, x2);
          _fieldInv(c, b);
          _fieldMul(c, c, a);
          _fieldMul(d, c, c);
          _fieldAdd(d, d, c);
          _fieldAdd(d, d, b);
          _fieldInc(d);
          _fieldAdd(x1, x1, d);
          _fieldMul(a, x1, c);
          _fieldAdd(a, a, d);
          _fieldAdd(y1, y1, a);
          _copy(x1, d);
        }
      }
    }
  }

  static void _pointMul(Uint32List x, Uint32List y, Uint32List exp) {
    final tmpx = Uint32List(bitvecNwords);
    final tmpy = Uint32List(bitvecNwords);
    final nbits = _degree(exp);
    _pointSetZero(tmpx, tmpy);
    for (int i = nbits - 1; i >= 0; --i) {
      _pointDouble(tmpx, tmpy);
      if (_getBit(exp, i) != 0) {
        _pointAdd(tmpx, tmpy, x, y);
      }
    }
    _pointCopy(x, y, tmpx, tmpy);
  }

  static bool _pointOnCurve(Uint32List x, Uint32List y) {
    final a = Uint32List(bitvecNwords);
    final b = Uint32List(bitvecNwords);
    if (_pointIsZero(x, y)) {
      return false;
    } else {
      _fieldMul(a, x, x);
      _fieldMul(b, a, x);
      _fieldAdd(a, a, b);
      _fieldAdd(a, a, _coeffB);
      _fieldMul(b, y, y);
      _fieldAdd(a, a, b);
      _fieldMul(b, x, y);
      return _equal(a, b);
    }
  }

  // ---- byte/word conversion --------------------------------------------------

  static Uint32List _bytesToInt(Uint8List bytes, int offset) {
    final value = Uint32List(bitvecNwords);
    int p = offset;
    for (int i = 0; i < bitvecNwords; i++) {
      value[i] = (bytes[p++]) |
          (bytes[p++] << 8) |
          (bytes[p++] << 16) |
          (bytes[p++] << 24);
    }
    return value;
  }

  static void _intsToBytes(Uint8List bytes, Uint32List ints, int offset) {
    int p = offset;
    for (int i = 0; i < bitvecNwords; i++) {
      bytes[p++] = ints[i] & 0xff;
      bytes[p++] = (ints[i] >> 8) & 0xff;
      bytes[p++] = (ints[i] >> 16) & 0xff;
      bytes[p++] = (ints[i] >> 24) & 0xff;
    }
  }

  // ---- ECDH ------------------------------------------------------------------

  static bool _generateKeys(Uint8List publicKey, Uint8List privateKey) {
    final priv = _bytesToInt(privateKey, 0);
    final pub1 = _bytesToInt(publicKey, 0);
    final pub2 = _bytesToInt(publicKey, bitvecNbytes);
    _pointCopy(pub1, pub2, _baseX, _baseY);

    if (_degree(priv) < (curveDegree ~/ 2)) {
      return false;
    } else {
      final nbits = _degree(_baseOrder);
      for (int i = nbits - 1; i < bitvecNwords * 32; ++i) {
        _clrBit(priv, i);
      }
      _pointMul(pub1, pub2, priv);
      _intsToBytes(publicKey, pub1, 0);
      _intsToBytes(publicKey, pub2, bitvecNbytes);
      return true;
    }
  }

  static bool _sharedSecret(
      Uint8List privateKey, Uint8List othersPub, Uint8List output) {
    final priv = _bytesToInt(privateKey, 0);
    final op1 = _bytesToInt(othersPub, 0);
    final op2 = _bytesToInt(othersPub, bitvecNbytes);

    if (!_pointIsZero(op1, op2) && _pointOnCurve(op1, op2)) {
      for (int i = 0; i < bitvecNbytes * 2; ++i) {
        output[i] = othersPub[i];
      }
      final nbits = _degree(_baseOrder);
      for (int i = nbits - 1; i < bitvecNwords * 32; ++i) {
        _clrBit(priv, i);
      }
      final out1 = _bytesToInt(output, 0);
      final out2 = _bytesToInt(output, bitvecNbytes);
      _pointMul(out1, out2, priv);
      _intsToBytes(output, out1, 0);
      _intsToBytes(output, out2, bitvecNbytes);
      return true;
    } else {
      return false;
    }
  }

  /// Generate the 48-byte public key for a 24-byte private key (random a-priori).
  /// Returns null if the private key is too small (caller should retry).
  static Uint8List? generatePublic(Uint8List privateEc) {
    final pub = Uint8List(eccPubKeySize);
    if (_generateKeys(pub, privateEc)) return pub;
    return null;
  }

  /// Compute the 48-byte shared secret. Returns null if the remote key is bad.
  static Uint8List? generateShared(Uint8List privateEc, Uint8List remotePublicEc) {
    final shared = Uint8List(eccPubKeySize);
    if (_sharedSecret(privateEc, remotePublicEc, shared)) return shared;
    return null;
  }
}
