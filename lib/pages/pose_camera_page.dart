import 'dart:typed_data';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:google_mlkit_commons/google_mlkit_commons.dart';

class PoseCameraPage extends StatefulWidget {
  const PoseCameraPage({super.key});

  @override
  State<PoseCameraPage> createState() => _PoseCameraPageState();
}

class _PoseCameraPageState extends State<PoseCameraPage>
    with WidgetsBindingObserver {
  CameraController? _cameraController;
  late PoseDetector _poseDetector;
  bool _isBusy = false;
  bool _isStreaming = false;
  bool _isDisposed = false;
  List<Pose> _poses = [];
  Size? _imageSize;
  CameraLensDirection _lensDirection = CameraLensDirection.front;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _poseDetector = PoseDetector(
        options: PoseDetectorOptions(mode: PoseDetectionMode.stream));
    _initializeCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _isDisposed = true;
    _stopStreamSafely();
    try {
      _cameraController?.dispose();
    } catch (_) {}
    try {
      _poseDetector.close();
    } catch (_) {}
    super.dispose();
  }

  void _stopStreamSafely() {
    try {
      if (_cameraController != null &&
          _cameraController!.value.isInitialized &&
          _cameraController!.value.isStreamingImages) {
        _cameraController!.stopImageStream();
      }
    } catch (e, st) {
      debugPrint('Ignored error stopping stream: $e\n$st');
    } finally {
      _isStreaming = false;
    }
  }

  void _startStreamSafely() {
    try {
      if (_cameraController != null &&
          _cameraController!.value.isInitialized &&
          !_cameraController!.value.isStreamingImages) {
        _cameraController!.startImageStream(_processCameraImage);
        _isStreaming = true;
      }
    } catch (e, st) {
      debugPrint('Ignored error starting stream: $e\n$st');
      _isStreaming = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_cameraController == null) return;
    if (!(_cameraController?.value.isInitialized ?? false)) return;
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _stopStreamSafely();
    } else if (state == AppLifecycleState.resumed) {
      _startStreamSafely();
    }
  }

  Future<void> _initializeCamera() async {
    try {
      final cameras = await availableCameras();
      final camera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );
      _lensDirection = camera.lensDirection;

      _cameraController = CameraController(
        camera,
        ResolutionPreset.high,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );

      await _cameraController!.initialize();
      if (_isDisposed) return;

      _startStreamSafely();

      if (mounted) setState(() {});
    } catch (e, st) {
      debugPrint('Camera init error: $e\n$st');
    }
  }

  InputImageRotation _rotationFromSensor(int sensorOrientation) {
    switch (sensorOrientation) {
      case 90:
        return InputImageRotation.rotation90deg;
      case 180:
        return InputImageRotation.rotation180deg;
      case 270:
        return InputImageRotation.rotation270deg;
      case 0:
      default:
        return InputImageRotation.rotation0deg;
    }
  }

  Uint8List _convertCameraImageToNV21(CameraImage image) {
    final width = image.width;
    final height = image.height;
    final yPlane = image.planes[0];
    final uPlane = image.planes[1];
    final vPlane = image.planes[2];

    final ySize = width * height;
    final uvSize = width * height ~/ 2;
    final nv21 = Uint8List(ySize + uvSize);

    int offset = 0;
    final yRowStride = yPlane.bytesPerRow;
    for (int row = 0; row < height; row++) {
      nv21.setRange(offset, offset + width,
          yPlane.bytes.sublist(row * yRowStride, row * yRowStride + width));
      offset += width;
    }

    final chromaHeight = (height / 2).floor();
    final chromaWidth = (width / 2).floor();
    final uRowStride = uPlane.bytesPerRow;
    final vRowStride = vPlane.bytesPerRow;
    final uPixelStride = uPlane.bytesPerPixel ?? 1;
    final vPixelStride = vPlane.bytesPerPixel ?? 1;

    for (int row = 0; row < chromaHeight; row++) {
      for (int col = 0; col < chromaWidth; col++) {
        final uIndex = row * uRowStride + col * uPixelStride;
        final vIndex = row * vRowStride + col * vPixelStride;
        nv21[offset++] = vPlane.bytes[vIndex];
        nv21[offset++] = uPlane.bytes[uIndex];
      }
    }
    return nv21;
  }

  Future<void> _processCameraImage(CameraImage cameraImage) async {
    if (_isBusy || _isDisposed) return;
    _isBusy = true;

    try {
      _imageSize =
          Size(cameraImage.width.toDouble(), cameraImage.height.toDouble());

      final rotation = _rotationFromSensor(
          _cameraController?.description.sensorOrientation ?? 0);

      final metadata = InputImageMetadata(
        size: _imageSize!,
        rotation: rotation,
        bytesPerRow: cameraImage.planes[0].bytesPerRow,
        format: InputImageFormat.nv21,
      );

      final inputImage = InputImage.fromBytes(
        bytes: _convertCameraImageToNV21(cameraImage),
        metadata: metadata,
      );

      final poses = await _poseDetector.processImage(inputImage);

      if (mounted && !_isDisposed) {
        setState(() {
          _poses = poses;
        });
      }
    } catch (e, st) {
      debugPrint('Processing frame failed: $e\n$st');
    } finally {
      _isBusy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          CameraPreview(_cameraController!),
          if (_poses.isNotEmpty && _imageSize != null)
            CustomPaint(
              painter: PoseSkeletonPainter(
                poses: _poses,
                imageSize: _imageSize!,
                isFront: _lensDirection == CameraLensDirection.front,
              ),
            ),
        ],
      ),
    );
  }
}

class PoseSkeletonPainter extends CustomPainter {
  final List<Pose> poses;
  final Size imageSize;
  final bool isFront;

  PoseSkeletonPainter({
    required this.poses,
    required this.imageSize,
    required this.isFront,
  });

  static final _circlePaint = Paint()
    ..color = Colors.red
    ..style = PaintingStyle.fill;

  static final _linePaint = Paint()
    ..color = Colors.green
    ..strokeWidth = 3.0
    ..style = PaintingStyle.stroke;

  Offset _mapLandmarkToCanvas(PoseLandmark lm, Size canvasSize) {
    double imgW = imageSize.width;
    double imgH = imageSize.height;

    double x = lm.x;
    double y = lm.y;

    // Miroir pour caméra front
    if (isFront) x = imgW - x;

    // Scale pour "cover" comme CameraPreview
    final scale = math.max(canvasSize.width / imgW, canvasSize.height / imgH);

    // Décalage pour centrer l’image sur le canvas
    final dx = (canvasSize.width - imgW * scale) / 2;
    final dy = (canvasSize.height - imgH * scale) / 2;

    return Offset(x * scale + dx, y * scale + dy);
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (poses.isEmpty) return;

    for (final pose in poses) {
      void drawPair(PoseLandmarkType a, PoseLandmarkType b) {
        final A = pose.landmarks[a];
        final B = pose.landmarks[b];
        if (A == null || B == null) return;
        final pA = _mapLandmarkToCanvas(A, size);
        final pB = _mapLandmarkToCanvas(B, size);
        canvas.drawLine(pA, pB, _linePaint);
      }

      for (final lm in pose.landmarks.values) {
        final p = _mapLandmarkToCanvas(lm, size);
        canvas.drawCircle(p, 6, _circlePaint);
      }

      // Torse
      drawPair(PoseLandmarkType.leftShoulder, PoseLandmarkType.rightShoulder);
      drawPair(PoseLandmarkType.leftHip, PoseLandmarkType.rightHip);
      drawPair(PoseLandmarkType.leftShoulder, PoseLandmarkType.leftHip);
      drawPair(PoseLandmarkType.rightShoulder, PoseLandmarkType.rightHip);

      // Bras
      drawPair(PoseLandmarkType.leftShoulder, PoseLandmarkType.leftElbow);
      drawPair(PoseLandmarkType.leftElbow, PoseLandmarkType.leftWrist);
      drawPair(PoseLandmarkType.rightShoulder, PoseLandmarkType.rightElbow);
      drawPair(PoseLandmarkType.rightElbow, PoseLandmarkType.rightWrist);

      // Jambes
      drawPair(PoseLandmarkType.leftHip, PoseLandmarkType.leftKnee);
      drawPair(PoseLandmarkType.leftKnee, PoseLandmarkType.leftAnkle);
      drawPair(PoseLandmarkType.rightHip, PoseLandmarkType.rightKnee);
      drawPair(PoseLandmarkType.rightKnee, PoseLandmarkType.rightAnkle);

      // Visage
      drawPair(PoseLandmarkType.leftEyeInner, PoseLandmarkType.rightEyeInner);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
