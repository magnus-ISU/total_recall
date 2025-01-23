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
import 'package:sqlite3/sqlite3.dart';

// Notification channel details
const notificationChannelId = 'transcription_service';
const notificationId = 888;

late Database db;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  directory = await getApplicationDocumentsDirectory();
  debugPrint(directory.path);
  dbCreate();

  if (isMobile) {
    await initializeBackgroundService();
  }

  if (Platform.isAndroid || Platform.isIOS) {
    await Permission.microphone.request();
  }

  runApp(const TotalRecallUI());
}

////////////////////////////////////////////////////////////////////////////////////////////////////
// Main UI
////////////////////////////////////////////////////////////////////////////////////////////////////

class TotalRecallUI extends StatelessWidget {
  const TotalRecallUI({super.key});

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
  final TextEditingController _textEditingController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  late final List<(DateTime, String)> messageHistory;
  final List<(DateTime, String)> newMessages = [];
  late final FlutterBackgroundService _service;

  @override
  void initState() {
    super.initState();
    _initializeApp();
    messageHistory = dbGetMessages().toList();
  }

  @override
  Widget build(BuildContext context) {
    final centerKey = Key('center');
    return Scaffold(
      appBar: AppBar(
        title: const Text('Live Transcription'),
      ),
      body: CustomScrollView(
        center: centerKey,
        anchor: 1,
        controller: _scrollController,
        slivers: [
          SliverFillRemaining(),
          _historyListView,
          SliverList.list(key: centerKey, children: []),
          _newMessagesListView,
          _currentlyTranscribingSentence,
        ],
      ),
    );
  }

  SliverList get _currentlyTranscribingSentence {
    final textField = TextField(
      controller: _textEditingController,
    );
    return SliverList.list(
      children: [textField],
    );
  }

  SliverList get _newMessagesListView {
    return SliverList.builder(
      itemCount: newMessages.length,
      itemBuilder: (BuildContext context, int index) {
        final (timestamp, messageText) = newMessages[index];
        return Text('${timestamp.toNiceString()}: ${messageText.toLowerCase()}');
      },
    );
  }

  SliverList get _historyListView {
    return SliverList.builder(
      itemCount: messageHistory.length,
      itemBuilder: (BuildContext context, int index) {
        if (index == messageHistory.length - 1) {
          // get new messages
          loadMoreHistory();
        }

        final (timestamp, messageText) = messageHistory[index];
        return Text('${timestamp.toNiceString()}: ${messageText.toLowerCase()}');
      },
    );
  }

  bool _isLoading = false;
  Future<void> loadMoreHistory() async {
    Future.delayed(Duration.zero).then((_) async {
      if (_isLoading) return;
      setState(() => _isLoading = true);
      setState(() {
        final newMessages = dbGetMessages(beforeIndex: messageHistory.length, beforeTime: _beforeHistoryTime);
        messageHistory.addAll(newMessages);
        if (newMessages.isNotEmpty) _isLoading = false;
      });
    });
  }

  void _continueScrollingToBottom() {
    if (_scrollController.hasClients) {
      final isAtBottom = _scrollController.offset >= _scrollController.position.maxScrollExtent - 50;
      if (isAtBottom) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    }
  }

  void updateText(String text, bool isEndpoint) {
    var timestamp = DateTime.now();
    var newText = '';
    if (text.isNotEmpty) newText = '${timestamp.toNiceString()}: $text';

    if (isEndpoint && text.isNotEmpty) {
      dbInsertMessage(timestamp.millisecondsSinceEpoch, text);
      final scroll = _scrollController.offset;
      final maxScroll = _scrollController.position.maxScrollExtent;
      final scrollPos = _scrollController.position;
      Future.delayed(Duration(seconds: 1)).then(
        (_) => debugPrint(
          'Scroll original: $scroll $maxScroll $scrollPos new: ${_scrollController.offset} ${_scrollController.position.maxScrollExtent} ${_scrollController.position}}',
        ),
      );
      setState(() {
        newMessages.add((timestamp, text));
      });
      newText = '';
    }

    _textEditingController.value = TextEditingValue(text: newText);
  }

  DateTime get _beforeHistoryTime => messageHistory.firstOrNull?.$1 ?? DateTime.now();

  Future<void> _initializeApp() async {
    if (isMobile) {
      // For mobile platforms, listen to background service updates
      _service = FlutterBackgroundService();
      _service.on('transcription').listen((event) {
        if (event != null) {
          updateText(event['text'], event['isEndpoint']);
        }
      });
    } else {
      await beginTranscription(updateText);
    }
  }

  @override
  void dispose() {
    _textEditingController?.dispose();
    _scrollController.dispose();
    super.dispose();
  }
}

class __TranscriptionScreenState extends State<TranscriptionScreen> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  String _previousFullSentences = '';
  late final FlutterBackgroundService _service;

  @override
  void initState() {
    super.initState();
    _initializeApp();
    _previousFullSentences = dbGetMessages().map((v) => '${v.$1.toNiceString()}: ${v.$2}').toList().join('\n');
    _controller.value = TextEditingValue(text: _previousFullSentences);
    _controller.selection = TextSelection.fromPosition(TextPosition(offset: _controller.text.length));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollController.jumpTo(
        _scrollController.position.maxScrollExtent,
      );
    });
  }

  void _animateScrollToBottom() {
    if (_scrollController.hasClients) {
      final isAtBottom = _scrollController.offset >= _scrollController.position.maxScrollExtent - 50;
      if (isAtBottom) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    }
  }

  void updateText(String text, bool isEndpoint) {
    var textToDisplay = _previousFullSentences;
    var timestamp = DateTime.now();
    var newText = '${timestamp.toNiceString()}: $text';
    if (text.isNotEmpty) {
      textToDisplay += '\n$newText';
    }

    if (isEndpoint) {
      if (text.isNotEmpty) {
        dbInsertMessage(timestamp.millisecondsSinceEpoch, text);
        if (_previousFullSentences.isNotEmpty) _previousFullSentences += '\n';
        _previousFullSentences += newText;
      }
    }

    _controller.value = TextEditingValue(text: textToDisplay);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _animateScrollToBottom();
    });
  }

  Future<void> _initializeApp() async {
    if (isMobile) {
      // For mobile platforms, listen to background service updates
      _service = FlutterBackgroundService();
      _service.on('transcription').listen((event) {
        if (event != null) {
          updateText(event['text'], event['isEndpoint']);
        }
      });
    } else {
      await beginTranscription(updateText);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Live Transcription'),
      ),
      body: TextField(
        controller: _controller,
        scrollController: _scrollController,
        maxLines: null,
        readOnly: true,
        expands: true,
        textAlignVertical: TextAlignVertical.bottom,
        decoration: const InputDecoration(
          border: OutlineInputBorder(),
          hintText: 'Transcription will appear here...',
          filled: true,
          fillColor: Colors.white,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }
}

////////////////////////////////////////////////////////////////////////////////////////////////////
// Recording and STT
////////////////////////////////////////////////////////////////////////////////////////////////////

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

late final Directory directory;
Future<String> copyAssetFile(String src) async {
  final dst = p.basename(src);
  final target = p.join(directory.path, dst);
  bool exists = await File(target).exists();

  final data = await rootBundle.load(src);

  if (!exists || File(target).lengthSync() != data.lengthInBytes) {
    final List<int> bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    await File(target).writeAsBytes(bytes);
  }

  return target;
}

Float32List bytesAsFloat32(Uint8List bytes) {
  final values = Float32List.view(bytes.buffer, bytes.offsetInBytes, bytes.length ~/ 4);
  return values;
}

class AudioProcessingService {
  final sherpa_onnx.OnlineRecognizer recognizer;
  final sherpa_onnx.OnlineStream stream;
  final void Function(String text, bool isEndpoint) onTranscriptionUpdate;

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
      onTranscriptionUpdate(text, isEndpoint);
    }

    if (isEndpoint) {
      recognizer.reset(stream);
    }
  }

  void dispose() {
    stream.free();
    recognizer.free();
  }
}

Future<AudioProcessingService> beginTranscription(
  final void Function(String text, bool isEndpoint) onTranscriptionUpdate,
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

  final audioProcessingService = AudioProcessingService(
    recognizer: recognizer,
    stream: stream,
    onTranscriptionUpdate: onTranscriptionUpdate,
  );

  Recorder.instance.uint8ListStream.listen(audioProcessingService.processAudioData);

  return audioProcessingService;
}

////////////////////////////////////////////////////////////////////////////////////////////////////
// DATABASE
////////////////////////////////////////////////////////////////////////////////////////////////////

void dbCreate() {
  db = sqlite3.open(databaseFilename);

  db.execute('''create table if not exists messages (
    text text not null,
    timestamp integer not null,
    id integer not null primary key
  )''');
}

final insertMessageSQL = db.prepare('insert into messages (timestamp, text) values (?, ?)');
void dbInsertMessage(int timestampMillisecondsSinceEpoch, String text) {
  insertMessageSQL.execute([timestampMillisecondsSinceEpoch, text]);
}

final getMessagesSQL = db.prepare('select timestamp, text from messages where timestamp <= ? order by timestamp desc limit 1000 offset ?');
Iterable<(DateTime, String)> dbGetMessages({int beforeIndex = 0, DateTime? beforeTime}) {
  final beforeTimeMillis = (beforeTime ?? DateTime.now()).millisecondsSinceEpoch;
  final ResultSet results = getMessagesSQL.select([beforeTimeMillis, beforeIndex]);
  return results.map((row) => (DateTime.fromMillisecondsSinceEpoch(row['timestamp'] as int), row['text'] as String)).toList();
}

String get databaseFilename => "total_recall.sqlite";

////////////////////////////////////////////////////////////////////////////////////////////////////
// Mobile background services
////////////////////////////////////////////////////////////////////////////////////////////////////

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

    final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();

    await flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
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

  await Permission.microphone.request();

  final processor = await beginTranscription((text, isEndpoint) {
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
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        },
      );
    }
  });

  service.on('stop').listen((event) {
    processor.dispose();
    service.stopSelf();
  });
}

////////////////////////////////////////////////////////////////////////////////////////////////////
// Misc
////////////////////////////////////////////////////////////////////////////////////////////////////

extension on DateTime {
  String toNiceString() {
    return '$year-$month-$day $hour:$minute:$second';
  }
}

bool get isMobile {
  return false;
//   return Platform.isAndroid || Platform.isIOS;
}
