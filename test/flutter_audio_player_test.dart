import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_audio_player/flutter_audio_player.dart';
import 'package:flutter_audio_player/flutter_audio_player_platform_interface.dart';
import 'package:flutter_audio_player/flutter_audio_player_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockFlutterAudioPlayerPlatform
    with MockPlatformInterfaceMixin
    implements FlutterAudioPlayerPlatform {

  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final FlutterAudioPlayerPlatform initialPlatform = FlutterAudioPlayerPlatform.instance;

  test('$MethodChannelFlutterAudioPlayer is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelFlutterAudioPlayer>());
  });

  test('getPlatformVersion', () async {
    FlutterAudioPlayer flutterAudioPlayerPlugin = FlutterAudioPlayer();
    MockFlutterAudioPlayerPlatform fakePlatform = MockFlutterAudioPlayerPlatform();
    FlutterAudioPlayerPlatform.instance = fakePlatform;

    expect(await flutterAudioPlayerPlugin.getPlatformVersion(), '42');
  });
}
