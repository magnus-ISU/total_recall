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
      title: 'Next-gen Kaldi flutter demo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const MyHomePage(title: 'Next-gen Kaldi with Flutter'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  int _currentIndex = 0;
  final List<Widget> _tabs = [
    const StreamingAsrScreen(),
  ];
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
      ),
      body: _tabs[_currentIndex],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (int index) {
          setState(() {
            _currentIndex = index;
          });
        },
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.home),
            label: 'Home',
          ),
        ],
      ),
    );
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

class StreamingAsrScreen extends StatefulWidget {
  const StreamingAsrScreen({super.key});

  @override
  State<StreamingAsrScreen> createState() => _StreamingAsrScreenState();
}

class _StreamingAsrScreenState extends State<StreamingAsrScreen> {
  late final TextEditingController _controller;

  final String _title = 'Real-time speech recognition';
  String _last = '';
  int _index = 0;
  bool _isInitialized = false;

  sherpa_onnx.OnlineRecognizer? _recognizer;
  sherpa_onnx.OnlineStream? _stream;
  final int _sampleRate = 16000;

  @override
  void initState() {
    _controller = TextEditingController();

    super.initState();
  }

  Future<void> _start() async {
    if (!_isInitialized) {
      sherpa_onnx.initBindings();
      _recognizer = await createOnlineRecognizer();
      _stream = _recognizer?.createStream();
	  
	  await [Permission.microphone].request();

      Recorder.instance.init(
        format: PCMFormat.s16le,
        sampleRate: 16000,
        channels: RecorderChannels.mono,
      );

      _isInitialized = true;
    }

    try {
      final captureDevices = Recorder.instance.listCaptureDevices();
      debugPrint(captureDevices.toString());

      Recorder.instance.uint8ListStream.listen(
        (audioDataContainer) {
          final data = audioDataContainer.rawData;
		  debugPrint("Samples: $data");
          final samplesFloat32 = convertBytesToFloat32(data);
		  debugPrint("f32: $samplesFloat32");

          _stream!.acceptWaveform(samples: samplesFloat32, sampleRate: _sampleRate);
          while (_recognizer!.isReady(_stream!)) {
            _recognizer!.decode(_stream!);
          }
          final text = _recognizer!.getResult(_stream!).text;
          String textToDisplay = _last;
          if (text != '') {
            if (_last == '') {
              textToDisplay = '$_index: $text';
            } else {
              textToDisplay = '$_index: $text\n$_last';
            }
          }

          if (_recognizer!.isEndpoint(_stream!)) {
            _recognizer!.reset(_stream!);
            if (text != '') {
              _last = textToDisplay;
              _index += 1;
            }
          }
          debugPrint('text: $textToDisplay');

          _controller.value = TextEditingValue(
            text: textToDisplay,
            selection: TextSelection.collapsed(offset: textToDisplay.length),
          );
        },
        onDone: () {
          debugPrint('stream stopped.');
        },
      );
    } catch (e) {
      debugPrint(e.toString());
    }

      Recorder.instance.startStreamingData();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          title: Text(_title),
        ),
        body: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(height: 50),
            TextField(
              maxLines: 5,
              controller: _controller,
              readOnly: true,
            ),
            const SizedBox(height: 50),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                _buildRecordStopControl(),
                const SizedBox(width: 20),
                _buildText(),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _stream?.free();
    _recognizer?.free();
    super.dispose();
  }

  Widget _buildRecordStopControl() {
    late Icon icon;
    late Color color;

    icon = const Icon(Icons.stop, color: Colors.red, size: 30);
    color = Colors.red;

    return ClipOval(
      child: Material(
        color: color,
        child: InkWell(
          child: SizedBox(width: 56, height: 56, child: icon),
          onTap: () => _start(),
        ),
      ),
    );
  }

  Widget _buildText() {
    return const Text("Start");
  }
}

// Copy the asset file from src to dst
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

Float32List convertBytesToFloat32(Uint8List bytes, [endian = Endian.little]) {
  final values = Float32List(bytes.length ~/ 2);

  final data = ByteData.view(bytes.buffer);

  for (var i = 0; i < bytes.length; i += 2) {
    int short = data.getInt16(i, endian);
    values[i ~/ 2] = short / 32678.0;
  }

  return values;
}
