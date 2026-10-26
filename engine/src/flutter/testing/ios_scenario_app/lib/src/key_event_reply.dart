// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';

import 'scenario.dart';

/// Posts reposnses to hardware key events on both key channels, to emulate
/// framework behavior.
///
/// `flutter/keydata` is answered synchronously, to match
/// `PlatformDispatcher.onKeyData` in the framework.
///
/// `flutter/keyevent` is answered either synchronously or from a microtask.
/// The framework answers it from a microtask: `_DefaultBinaryMessenger` sends
/// the reply after `await handler(data)`.
///
/// Sends a message on `key_event_reply_ready` once both handlers are installed.
class KeyEventReplyScenario extends Scenario {
  /// Creates the scenario and installs the key channel handlers.
  KeyEventReplyScenario(super.view, {required this.replyFromMicrotask}) {
    view.platformDispatcher.onKeyData = (KeyData data) => true;
    channelBuffers.setListener(_keyEventChannel, _onKeyEvent);
    view.platformDispatcher.sendPlatformMessage('key_event_reply_ready', null, null);
  }

  /// Whether `flutter/keyevent` is answered from a microtask instead of
  /// synchronously.
  final bool replyFromMicrotask;

  static const String _keyEventChannel = 'flutter/keyevent';

  static final ByteData _handledReply = ByteData.sublistView(
    utf8.encode(json.encode(<String, Object>{'handled': true})),
  );

  void _onKeyEvent(ByteData? data, PlatformMessageResponseCallback callback) {
    if (replyFromMicrotask) {
      scheduleMicrotask(() => callback(_handledReply));
    } else {
      callback(_handledReply);
    }
  }

  @override
  void onBeginFrame(Duration duration) {}

  @override
  void onDrawFrame() {}

  @override
  void unmount() {
    channelBuffers.clearListener(_keyEventChannel);
    view.platformDispatcher.onKeyData = null;
    super.unmount();
  }
}
