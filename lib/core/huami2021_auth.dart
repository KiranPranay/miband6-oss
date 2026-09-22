part of 'ble_manager.dart';

// The handshake sequence below follows Gadgetbridge's `InitOperation2021`
//   Copyright (C) 2022-2024 Andreas Shimokawa and the Gadgetbridge contributors
//   https://codeberg.org/Freeyourgadget/Gadgetbridge
// This is an independent Dart implementation of the wire protocol rather than a
// translation of their code, but it was written from their source and the debt
// is acknowledged here. See NOTICE.md.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

// ===========================================================================
// Huami 2021 "sign-key" authentication (ECDH) over the chunked transport.
//
// This Mi Band 6 firmware rejects the legacy AES-ECB auth with status 0x07
// ("sign key failed", findings-06). It requires the ECDH handshake of
// Gadgetbridge's InitOperation2021 over fee0/0x0016 (write) + 0x0017 (notify),
// endpoint 0x0082:
//   → 04 02 00 02 <publicEC(48)>
//   ← 10 04 01 <remoteRandom(16)> <remotePublicEC(48)>
//     sharedEC      = ECDH(privateEC, remotePublicEC)
//     seqNr         = LE32(sharedEC[0..3])
//     sessionKey[i] = sharedEC[i+8] ^ authKey[i]            (16 bytes)
//   → 05 <AES_ECB(authKey, remoteRandom)> <AES_ECB(sessionKey, remoteRandom)>
//   ← 10 05 01            → authenticated   (10 05 25 → wrong key)
// After success the session key encrypts the chunked data channel.
// ===========================================================================

const int _chunked2021EndpointAuth = 0x0082;

extension Huami2021Auth on BLEManager {
  /// Whether the band exposes the chunked transport needed for sign-key auth.
  bool get hasChunkedTransport =>
      _chunkedWriteChar != null && _chunkedNotifyChar != null;

  /// Run the Huami 2021 ECDH sign-key authentication. Returns false if it could
  /// not be started (missing chars/key).
  Future<bool> start2021Auth() async {
    if (!hasChunkedTransport) return false;
    final secretKey = await _storage.getAuthKeyBytes();
    if (secretKey == null || secretKey.length != 16) {
      _logger.e("2021 auth: auth key missing/invalid (need 16 bytes)");
      _failAuth();
      return false;
    }

    _isAuthenticating = true;
    _setAuthState(AuthState.authenticating);
    _emitChange();

    try {
      _mtu = _device!.mtuNow;
    } catch (_) {}

    // Generate an ECDH-B163 key pair (retry if the random scalar is too small).
    final rnd = Random.secure();
    Uint8List? pub;
    for (int attempt = 0; attempt < 8 && pub == null; attempt++) {
      _privateEC =
          Uint8List.fromList(List.generate(24, (_) => rnd.nextInt(256)));
      pub = EcdhB163.generatePublic(_privateEC!);
    }
    if (pub == null) {
      _logger.e("2021 auth: ECDH key generation failed");
      _failAuth();
      return false;
    }

    _chunkedEncoder = Huami2021ChunkedEncoder(_mtu);
    _chunkedDecoder =
        Huami2021ChunkedDecoder(_handle2021Payload, force2021Protocol: true);

    // Subscribe to the chunked notify char (0x0017).
    try {
      await _chunkedNotifyChar!.setNotifyValue(true);
    } catch (e) {
      _logger.e("2021 auth: failed to enable 0x0017 notify: $e");
      _failAuth();
      return false;
    }
    _chunkedSub?.cancel();
    _chunkedSub = _chunkedNotifyChar!.onValueReceived.listen((value) {
      if (value.isEmpty || value[0] != 0x03) return;
      final needsAck = _chunkedDecoder!.decode(Uint8List.fromList(value));
      if (needsAck) sendChunkedAck();
    });

    _authTimeoutTimer?.cancel();
    _authTimeoutTimer = Timer(const Duration(seconds: 20), () {
      _logger.e("2021 auth timeout");
      _isAuthenticating = false;
      _setAuthState(AuthState.failed);
      _emitChange();
    });

    // Send the public key: 04 02 00 02 + publicEC(48).
    final cmd = Uint8List(52);
    cmd[0] = 0x04;
    cmd[1] = 0x02;
    cmd[2] = 0x00;
    cmd[3] = 0x02;
    cmd.setRange(4, 52, pub);
    _logger.i("2021 auth: sending ECDH public key (52 B) to 0x0016 (mtu=$_mtu)");
    await _writeChunked(_chunked2021EndpointAuth, cmd, encrypt: false);
    return true;
  }

  Future<void> _handle2021Payload(int type, Uint8List payload) async {
    if (type != _chunked2021EndpointAuth) {
      _handle2021Data(type, payload);
      return;
    }
    final hex =
        payload.take(8).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
    _logger.d("2021 auth payload (type=0x82): $hex …");

    if (payload.length >= 67 &&
        payload[0] == 0x10 &&
        payload[1] == 0x04 &&
        payload[2] == 0x01) {
      // Remote random (16) + remote public key (48).
      final remoteRandom = Uint8List.sublistView(payload, 3, 19);
      final remotePublic = Uint8List.sublistView(payload, 19, 67);
      final sharedEC = EcdhB163.generateShared(_privateEC!, remotePublic);
      if (sharedEC == null) {
        _authTimeoutTimer?.cancel();
        _logger.e("2021 auth: ECDH shared-secret computation failed");
        _failAuth();
        return;
      }
      final secretKey = (await _storage.getAuthKeyBytes())!;
      final seqNr = sharedEC[0] |
          (sharedEC[1] << 8) |
          (sharedEC[2] << 16) |
          (sharedEC[3] << 24);
      final sessionKey = Uint8List(16);
      for (int i = 0; i < 16; i++) {
        sessionKey[i] = (sharedEC[i + 8] ^ secretKey[i]) & 0xff;
      }
      _sessionKey = sessionKey;
      _chunkedEncoder!.setEncryptionParameters(seqNr, sessionKey);
      _chunkedDecoder!.setEncryptionParameters(sessionKey);
      _logger.i("2021 auth: shared session key derived; "
          "sending double-encrypted random");

      final enc1 = BLEEncryption.encryptAESECB(secretKey, remoteRandom);
      final enc2 = BLEEncryption.encryptAESECB(sessionKey, remoteRandom);
      final cmd = Uint8List(33);
      cmd[0] = 0x05;
      cmd.setRange(1, 17, enc1);
      cmd.setRange(17, 33, enc2);
      await _writeChunked(_chunked2021EndpointAuth, cmd, encrypt: false);
    } else if (payload.length >= 3 &&
        payload[0] == 0x10 &&
        payload[1] == 0x05 &&
        payload[2] == 0x01) {
      _authTimeoutTimer?.cancel();
      _logger.i("2021 SIGN-KEY AUTHENTICATION SUCCESS!");
      _isAuthenticating = false;
      _setAuthState(AuthState.authenticated);
      _emitChange();
      _onAuthSuccess();
    } else if (payload.length >= 3 &&
        payload[0] == 0x10 &&
        payload[1] == 0x05 &&
        payload[2] == 0x25) {
      _authTimeoutTimer?.cancel();
      _logger.e("2021 auth FAILED — wrong key (status 0x25)");
      _failAuth();
    } else {
      _logger.e("2021 auth: unhandled payload $hex …");
    }
  }

  /// Frame [data] for [type] via the encoder and write each chunk to 0x0016.
  Future<void> _writeChunked(int type, Uint8List data,
      {required bool encrypt}) async {
    final enc = _chunkedEncoder;
    final ch = _chunkedWriteChar;
    if (enc == null || ch == null) return;
    final chunks = <Uint8List>[];
    try {
      enc.write((c) => chunks.add(c), type, data, true, encrypt);
    } catch (e) {
      _logger.e("chunked encode error: $e");
      return;
    }
    final noResp = !ch.properties.write && ch.properties.writeWithoutResponse;
    for (final c in chunks) {
      try {
        await ch.write(c, withoutResponse: noResp);
      } catch (e) {
        _logger.e("chunked write error: $e");
      }
    }
  }

  /// Ack a chunked frame that requested it (`04 00 handle 01 count` → 0x0017).
  Future<void> sendChunkedAck() async {
    final ch = _chunkedNotifyChar;
    final dec = _chunkedDecoder;
    if (ch == null || dec == null) return;
    final ack =
        Uint8List.fromList([0x04, 0x00, dec.lastHandle, 0x01, dec.lastCount]);
    final noResp = !ch.properties.write && ch.properties.writeWithoutResponse;
    try {
      await ch.write(ack, withoutResponse: noResp);
    } catch (e) {
      _logger.e("chunked ack write error: $e");
    }
  }

  /// Data payloads (non-auth endpoints) arriving over the chunked channel.
  /// Logged for now; the post-auth path first tries the standard chars (full
  /// auth may unlock the 0x180D HR service / fee0 fetch that partial auth blocked).
  /// Non-auth chunked-2021 payloads. Two endpoints are watched for the
  /// experimental probes (protocol-mb6.md §13-14); everything else is logged
  /// so an unexpected endpoint shows up in the Debug Console.
  void _handle2021Data(int type, Uint8List payload) {
    final hex = payload
        .take(16)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join(' ');
    switch (type) {
      case 0x000a:
        // ZeppOS config endpoint. `06` = CMD_ACK (GB ZeppOsConfigService:111).
        // Half of the P14.2 pass criterion; the other half is automatic SpO2
        // records appearing in the 0x25 fetch.
        _logger.i(payload.isNotEmpty && payload[0] == 0x06
            ? 'P14.2: band ACKed the SpO2 auto-monitoring config ($hex)'
            : 'P14.2: config endpoint replied $hex (not an ack)');
        break;
      case 0x0013:
        _onCannedReplyPayload(payload, hex);
        break;
      default:
        _logger.i("2021 chunked data (type=0x${type.toRadixString(16)}): $hex");
    }
  }

  /// Canned-reply endpoint, from the block GB ships disabled
  /// (`HuamiSupport.java:3979-4011`, "unsafe for now"). §13.2.
  ///
  /// `06`/`08` are set/delete acks. `0d` asks whether SMS reply is allowed;
  /// we answer `0e 01`. `0b` carries the caller's number and the chosen text:
  /// `0b | number ASCII | 00 | 4 unknown | text | 1 trailing`.
  Future<void> _onCannedReplyPayload(Uint8List p, String hex) async {
    if (p.isEmpty) return;
    switch (p[0]) {
      case 0x06:
        _logger.i('P13.1: band ACKed a canned-reply set ($hex)');
        return;
      case 0x08:
        _logger.d('P13.1: canned-reply delete ack');
        return;
      case 0x0d:
        _logger.i('P13.1: band asked if SMS reply is allowed — answering yes');
        await _writeChunked(0x0013, Uint8List.fromList([0x0e, 0x01]), encrypt: false);
        return;
      case 0x0b:
        final nul = p.indexOf(0, 1);
        if (nul < 0 || p.length < nul + 6) {
          _logger.e('P13.1: reply frame too short to parse: $hex');
          return;
        }
        final number = String.fromCharCodes(p.sublist(1, nul));
        final text = String.fromCharCodes(p.sublist(nul + 5, p.length - 1));
        _logger.i('P13.1: band chose reply "$text" for ${number.length > 4 ? '${number.substring(0, 4)}…' : number}');
        final ended = await callControl.endCall();
        final sent = number.isNotEmpty && text.isNotEmpty
            ? await callControl.sendSms(number, text)
            : false;
        _logger.i('P13.1: endCall=$ended sendSms=$sent');
        await _writeChunked(0x0013, Uint8List.fromList([0x0c, 0x01]), encrypt: false);
        return;
      default:
        _logger.i('P13.1: canned-reply endpoint sent $hex');
    }
  }

  void _disposeChunked() {
    _chunkedSub?.cancel();
    _chunkedSub = null;
    _chunkedEncoder = null;
    _chunkedDecoder = null;
    _chunkedWriteChar = null;
    _chunkedNotifyChar = null;
    _privateEC = null;
    _sessionKey = null;
  }
}
