import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'flutter_audio_player_method_channel.dart';

abstract class FlutterAudioPlayerPlatform extends PlatformInterface {
  /// Constructs a FlutterAudioPlayerPlatform.
  FlutterAudioPlayerPlatform() : super(token: _token);

  static final Object _token = Object();

  static FlutterAudioPlayerPlatform _instance = MethodChannelFlutterAudioPlayer();

  /// The default instance of [FlutterAudioPlayerPlatform] to use.
  ///
  /// Defaults to [MethodChannelFlutterAudioPlayer].
  static FlutterAudioPlayerPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [FlutterAudioPlayerPlatform] when
  /// they register themselves.
  static set instance(FlutterAudioPlayerPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
