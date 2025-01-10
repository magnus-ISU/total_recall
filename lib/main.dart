// Copyright (c)  2024  Xiaomi Corporation
import 'package:flutter/material.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'dart:typed_data';
import "dart:io";

class InfoScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    const double height = 20;
    return Container(
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('Everything is open-sourced.'),
            const SizedBox(height: height),
            InkWell(
              child: const Text('Code: https://github.com/k2-fsa/sherpa-onnx'),
              onTap: () => {},
            ),
            const SizedBox(height: height),
            InkWell(
              child: const Text('Doc: https://k2-fsa.github.io/sherpa/onnx/'),
              onTap: () => {},
            ),
            const SizedBox(height: height),
            const Text('QQ 群: 744602236'),
            const SizedBox(height: height),
            InkWell(
              child: const Text(
                  '微信群: https://k2-fsa.github.io/sherpa/social-groups.html'),
              onTap: () => {},
            ),
          ],
        ),
      ),
    );
  }
}

// Copyright (c)  2024  Xiaomi Corporation

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
    InfoScreen(),
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
          BottomNavigationBarItem(
            icon: Icon(Icons.info),
            label: 'Info',
          ),
        ],
      ),
    );
  }
}

// Remember to change `assets` in ../pubspec.yaml
// and download files to ../assets
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

// Copyright (c)  2024  Xiaomi Corporation

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
  late final AudioRecorder _audioRecorder;

  final String _title = 'Real-time speech recognition';
  String _last = '';
  int _index = 0;
  bool _isInitialized = false;

  sherpa_onnx.OnlineRecognizer? _recognizer;
  sherpa_onnx.OnlineStream? _stream;
  final int _sampleRate = 16000;

  StreamSubscription<RecordState>? _recordSub;
  RecordState _recordState = RecordState.stop;

  @override
  void initState() {
    _audioRecorder = AudioRecorder();
    _controller = TextEditingController();

    _recordSub = _audioRecorder.onStateChanged().listen((recordState) {
      _updateRecordState(recordState);
    });

    super.initState();
  }

  Future<void> _start() async {
    if (!_isInitialized) {
      sherpa_onnx.initBindings();
      _recognizer = await createOnlineRecognizer();
      _stream = _recognizer?.createStream();

      _isInitialized = true;
    }

    try {
      if (await _audioRecorder.hasPermission()) {
        const encoder = AudioEncoder.pcm16bits;

        if (!await _isEncoderSupported(encoder)) {
          return;
        }

        final devs = await _audioRecorder.listInputDevices();
        debugPrint(devs.toString());

        const config = RecordConfig(
          encoder: encoder,
          sampleRate: 16000,
          numChannels: 1,
        );

        final stream = await _audioRecorder.startStream(config);

        stream.listen(
          (data) {
            final samplesFloat32 =
                convertBytesToFloat32(Uint8List.fromList(data));

            _stream!.acceptWaveform(
                samples: samplesFloat32, sampleRate: _sampleRate);
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
            // print('text: $textToDisplay');

            _controller.value = TextEditingValue(
              text: textToDisplay,
              selection: TextSelection.collapsed(offset: textToDisplay.length),
            );
          },
          onDone: () {
            print('stream stopped.');
          },
        );
      }
    } catch (e) {
      print(e);
    }
  }

  Future<void> _stop() async {
    _stream!.free();
    _stream = _recognizer!.createStream();

    await _audioRecorder.stop();
  }

  Future<void> _pause() => _audioRecorder.pause();

  Future<void> _resume() => _audioRecorder.resume();

  void _updateRecordState(RecordState recordState) {
    setState(() => _recordState = recordState);
  }

  Future<bool> _isEncoderSupported(AudioEncoder encoder) async {
    final isSupported = await _audioRecorder.isEncoderSupported(
      encoder,
    );

    if (!isSupported) {
      debugPrint('${encoder.name} is not supported on this platform.');
      debugPrint('Supported encoders are:');

      for (final e in AudioEncoder.values) {
        if (await _audioRecorder.isEncoderSupported(e)) {
          debugPrint('- ${encoder.name}');
        }
      }
    }

    return isSupported;
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
    _recordSub?.cancel();
    _audioRecorder.dispose();
    _stream?.free();
    _recognizer?.free();
    super.dispose();
  }

  Widget _buildRecordStopControl() {
    late Icon icon;
    late Color color;

    if (_recordState != RecordState.stop) {
      icon = const Icon(Icons.stop, color: Colors.red, size: 30);
      color = Colors.red.withOpacity(0.1);
    } else {
      final theme = Theme.of(context);
      icon = Icon(Icons.mic, color: theme.primaryColor, size: 30);
      color = theme.primaryColor.withOpacity(0.1);
    }

    return ClipOval(
      child: Material(
        color: color,
        child: InkWell(
          child: SizedBox(width: 56, height: 56, child: icon),
          onTap: () {
            (_recordState != RecordState.stop) ? _stop() : _start();
          },
        ),
      ),
    );
  }

  Widget _buildText() {
    if (_recordState == RecordState.stop) {
      return const Text("Start");
    } else {
      return const Text("Stop");
    }
  }
}


// Copy the asset file from src to dst
Future<String> copyAssetFile(String src, [String? dst]) async {
  final Directory directory = await getApplicationDocumentsDirectory();
  if (dst == null) {
    dst = basename(src);
  }
  final target = join(directory.path, dst);
  bool exists = await new File(target).exists();

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

