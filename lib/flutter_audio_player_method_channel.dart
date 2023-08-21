import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'flutter_audio_player_platform_interface.dart';

/// An implementation of [FlutterAudioPlayerPlatform] that uses method channels.
class MethodChannelFlutterAudioPlayer extends FlutterAudioPlayerPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('flutter_audio_player');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>('getPlatformVersion');
    return version;
  }
}
