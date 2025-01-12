import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/material.dart';
import 'package:flutter_recorder/flutter_recorder.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:flutter/services.dart' show rootBundle;
import "dart:io";

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Total Recall',
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
  late final TextEditingController _controller;
  String _last = '';
  int _index = 0;
  bool _isInitialized = false;

  late sherpa_onnx.OnlineRecognizer _recognizer;
  late sherpa_onnx.OnlineStream _stream;
  final int _sampleRate = 16000;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
    _initializeAndStart();
  }

  Future<void> _initializeAndStart() async {
    if (!_isInitialized) {
      sherpa_onnx.initBindings();
      _recognizer = await createOnlineRecognizer();
      _stream = _recognizer.createStream();

      if (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS) {
        var permissionStatus = await Permission.microphone.request();
        if (permissionStatus.isDenied) {
          // Handle permission denied case
          return;
        }
      }

      await Recorder.instance.init(
        format: PCMFormat.f32le,
        sampleRate: 16000,
        channels: RecorderChannels.mono,
      );
      
      _isInitialized = true;
      await _startTranscription();
    }
  }

  Future<void> _startTranscription() async {
    try {
      Recorder.instance.start();
      
      Recorder.instance.uint8ListStream.listen(
        (audioDataContainer) {
          final data = audioDataContainer.rawData;
          final samplesFloat32 = bytesAsFloat32(data);

          _stream.acceptWaveform(samples: samplesFloat32, sampleRate: _sampleRate);
          while (_recognizer.isReady(_stream)) {
            _recognizer.decode(_stream);
          }
          final text = _recognizer.getResult(_stream).text;
          String textToDisplay = _last;
          if (text != '') {
            if (_last == '') {
              textToDisplay = '$_index: $text';
            } else {
              textToDisplay = '$_index: $text\n$_last';
            }
          }

          if (_recognizer.isEndpoint(_stream)) {
            _recognizer.reset(_stream);
            if (text != '') {
              _last = textToDisplay;
              _index += 1;
            }
          }

          _controller.value = TextEditingValue(
            text: textToDisplay,
            selection: TextSelection.collapsed(offset: textToDisplay.length),
          );
        },
        onDone: () {
          debugPrint('stream stopped.');
        },
      );

      Recorder.instance.startStreamingData();
    } catch (e) {
      debugPrint('Error starting transcription: $e');
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
    _stream.free();
    _recognizer.free();
    _controller.dispose();
    super.dispose();
  }
}

Future<sherpa_onnx.OnlineModelConfig> getOnlineModelConfig() async {
  const modelDir = 'assets/sherpa-onnx-streaming-zipformer-en-2023-06-26';
  return sherpa_onnx.OnlineModelConfig(
    transducer: sherpa_onnx.OnlineTransducerModelConfig(
      encoder: await copyAssetFile(
          '$modelDir/encoder-epoch-99-avg-1-chunk-16-left-128.int8.onnx'),
      decoder: await copyAssetFile(
          '$modelDir/decoder-epoch-99-avg-1-chunk-16-left-128.onnx'),
      joiner: await copyAssetFile(
          '$modelDir/joiner-epoch-99-avg-1-chunk-16-left-128.onnx'),
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
