import 'dart:ui';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/material.dart';
import 'package:flutter_recorder/flutter_recorder.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:flutter/services.dart' show rootBundle;
import 'dart:io';

// Notification channel details
const notificationChannelId = 'transcription_service';
const notificationId = 888;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (Platform.isAndroid || Platform.isIOS) {
    await initializeBackgroundService();
  }

  runApp(const MyApp());
}

Future<void> initializeBackgroundService() async {
  final service = FlutterBackgroundService();

  // Configure notifications for Android
  if (Platform.isAndroid) {
    const AndroidNotificationChannel channel = AndroidNotificationChannel(
      notificationChannelId,
      'Transcription Service',
      description: 'Running speech recognition in background',
      importance: Importance.low,
    );

    final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
        FlutterLocalNotificationsPlugin();

    await flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);
  }

  await service.configure(
    iosConfiguration: IosConfiguration(
      autoStart: true,
      onForeground: onMobileStart,
      onBackground: onIosBackground,
    ),
    androidConfiguration: AndroidConfiguration(
      onStart: onMobileStart,
      autoStart: true,
      isForegroundMode: true,
      notificationChannelId: notificationChannelId,
      initialNotificationTitle: 'Transcription Service',
      initialNotificationContent: 'Initializing...',
      foregroundServiceNotificationId: notificationId,
      autoStartOnBoot: true,
    ),
  );
}

@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  return true;
}

@pragma('vm:entry-point')
void onMobileStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  // Request microphone permission if needed
  await Permission.microphone.request();

  final processor = await audioProcessor((text, isEndpoint, sentenceIndex) {
    if (service is AndroidServiceInstance) {
      service.setForegroundNotificationInfo(
        title: 'Transcription Active',
        content: text,
      );
      service.invoke(
        'transcription',
        {
          'text': text,
          'isEndpoint': isEndpoint,
          'sentenceIndex': sentenceIndex,
          'timestamp': DateTime.now().toIso8601String(),
        },
      );
    }
  });

  // Start recording
  Recorder.instance.uint8ListStream.listen(processor.processAudioData);

  // Handle stop command
  service.on('stop').listen((event) {
    processor.dispose();
    service.stopSelf();
  });
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Transcription App',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const TranscriptionScreen(),
    );
  }
}

class TranscriptionScreen extends StatefulWidget {
  const TranscriptionScreen({super.key});

  @override
  State<TranscriptionScreen> createState() => _TranscriptionScreenState();
}

class _TranscriptionScreenState extends State<TranscriptionScreen> {
  final TextEditingController _controller = TextEditingController();
  final List<String> _previousFullSentences = [];
  late final FlutterBackgroundService _service;

  @override
  void initState() {
    super.initState();
    _initializeApp();
  }
  
  void updateText(String text, bool isEndpoint, int sentenceIndex) {
      var textToDisplay = _previousFullSentences.join('\n');
      var newText = '$sentenceIndex: $text';
      if (text.isNotEmpty) {
        textToDisplay += '\n$newText';
      }

      if (isEndpoint) {
        if (text.isNotEmpty) {
          _previousFullSentences.add(newText);
        }
      }

      _controller.value = TextEditingValue(
        text: textToDisplay,
        selection: TextSelection.collapsed(offset: textToDisplay.length),
      );
  }

  Future<void> _initializeApp() async {
    _service = FlutterBackgroundService();

    if (Platform.isAndroid || Platform.isIOS) {
      // For mobile platforms, listen to background service updates
      _service.on('transcription').listen((event) {
        if (event != null) {
          updateText(event['text'], event['isEndpoint'], event['sentenceIndex']);
        }
      });
    } else {
    final processor = await audioProcessor(updateText);
    Recorder.instance.start();
    Recorder.instance.uint8ListStream.listen(processor.processAudioData);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Live Transcription'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: TextField(
          maxLines: null,
          controller: _controller,
          readOnly: true,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            hintText: 'Transcription will appear here...',
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}

Future<sherpa_onnx.OnlineModelConfig> getOnlineModelConfig() async {
  const modelDir = 'assets/sherpa-onnx-streaming-zipformer-en-2023-06-26';
  return sherpa_onnx.OnlineModelConfig(
    transducer: sherpa_onnx.OnlineTransducerModelConfig(
      encoder: await copyAssetFile(
        '$modelDir/encoder-epoch-99-avg-1-chunk-16-left-128.int8.onnx',
      ),
      decoder: await copyAssetFile(
        '$modelDir/decoder-epoch-99-avg-1-chunk-16-left-128.onnx',
      ),
      joiner: await copyAssetFile(
        '$modelDir/joiner-epoch-99-avg-1-chunk-16-left-128.onnx',
      ),
    ),
    tokens: await copyAssetFile('$modelDir/tokens.txt'),
    modelType: 'zipformer2',
  );
}

Future<sherpa_onnx.OnlineRecognizer> createOnlineRecognizer() async {
  final modelConfig = await getOnlineModelConfig();
  final config = sherpa_onnx.OnlineRecognizerConfig(
    model: modelConfig,
    ruleFsts: '',
  );
  return sherpa_onnx.OnlineRecognizer(config);
}

Future<String> copyAssetFile(String src) async {
  final Directory directory = await getApplicationDocumentsDirectory();
  final dst = p.basename(src);
  final target = p.join(directory.path, dst);
  bool exists = await File(target).exists();

  final data = await rootBundle.load(src);

  if (!exists || File(target).lengthSync() != data.lengthInBytes) {
    final List<int> bytes =
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    await File(target).writeAsBytes(bytes);
  }

  return target;
}

Float32List bytesAsFloat32(Uint8List bytes) {
  final values =
      Float32List.view(bytes.buffer, bytes.offsetInBytes, bytes.length ~/ 4);
  return values;
}

class AudioProcessingService {
  final sherpa_onnx.OnlineRecognizer recognizer;
  final sherpa_onnx.OnlineStream stream;
  final void Function(String text, bool isEndpoint, int processedIndex)
      onTranscriptionUpdate;

  int processedIndex = 0;

  AudioProcessingService({
    required this.recognizer,
    required this.stream,
    required this.onTranscriptionUpdate,
  });

  void processAudioData(AudioDataContainer audioDataContainer) {
    final data = audioDataContainer.rawData;
    final samplesFloat32 = bytesAsFloat32(data);

    stream.acceptWaveform(samples: samplesFloat32, sampleRate: 16000);
    while (recognizer.isReady(stream)) {
      recognizer.decode(stream);
    }

    final text = recognizer.getResult(stream).text;
    bool isEndpoint = recognizer.isEndpoint(stream);

    if (text.isNotEmpty || isEndpoint) {
      onTranscriptionUpdate(text, isEndpoint, processedIndex);
    }

    if (isEndpoint) {
      recognizer.reset(stream);
      processedIndex++;
    }
  }

  void dispose() {
    stream.free();
    recognizer.free();
  }
}
Future<AudioProcessingService> audioProcessor(
  final void Function(String text, bool isEndpoint, int processedIndex)
      onTranscriptionUpdate,
) async {
  // Initialize recorder
  await Recorder.instance.init(
    format: PCMFormat.f32le,
    sampleRate: 16000,
    channels: RecorderChannels.mono,
  );
  Recorder.instance.start();
  Recorder.instance.startStreamingData();

  // Initialize recognizer and stream
  sherpa_onnx.initBindings();
  final recognizer = await createOnlineRecognizer();
  final stream = recognizer.createStream();

  return AudioProcessingService(
    recognizer: recognizer,
    stream: stream,
    onTranscriptionUpdate: onTranscriptionUpdate,
  );
}
