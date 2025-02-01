macos: assets
	cd flutter; flutter run -d macos

android: assets
	cd flutter; flutter build apk --release
	cp flutter/build/app/outputs/flutter-apk/app-release.apk total_recall.apk

assets:
	cd flutter/assets ; if [ ! -f "sherpa-onnx-streaming-zipformer-en-2023-06-26.tar.bz2" ] ; then \
		wget https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-streaming-zipformer-en-2023-06-26.tar.bz2 ; \
	fi ; if [ ! -d "sherpa-onnx-streaming-zipformer-en-2023-06-26" ]; then \
		unar sherpa-onnx-streaming-zipformer-en-2023-06-26.tar.bz2 ; \
	fi

