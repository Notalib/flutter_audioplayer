
import 'flutter_audio_player_platform_interface.dart';

class FlutterAudioPlayer {
  Future<String?> getPlatformVersion() {
    return FlutterAudioPlayerPlatform.instance.getPlatformVersion();
  }
}
