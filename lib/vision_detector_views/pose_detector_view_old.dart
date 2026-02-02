import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:flutter_tts/flutter_tts.dart';

import 'detector_view.dart';
import 'painters/pose_painter.dart';
import 'curl_counter.dart';


class PoseDetectorView extends StatefulWidget {
  const PoseDetectorView({Key? key}) : super(key: key);

  @override
  State<PoseDetectorView> createState() => _PoseDetectorViewState();
}

class _PoseDetectorViewState extends State<PoseDetectorView> {
  final PoseDetector _poseDetector = PoseDetector(
    options: PoseDetectorOptions(),
  );

  final CurlCounter _curlCounter = CurlCounter(); // Notre compteur
  final FlutterTts _flutterTts = FlutterTts(); // TTS

  bool _canProcess = true;
  bool _isBusy = false;
  CustomPaint? _customPaint;
  String? _text;
  var _cameraLensDirection = CameraLensDirection.front;

  @override
  void initState() {
    super.initState();
    // Configuration TTS
    _flutterTts.setLanguage('fr-FR');
    _flutterTts.setSpeechRate(0.5);
    _flutterTts.setVolume(1.0);
  }

  @override
  void dispose() {
    _canProcess = false;
    _poseDetector.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Stack(
        children: [
          // DetectorView qui capture la caméra et appelle _processImage
          DetectorView(
            title: 'Pose Detector',
            customPaint: _customPaint,
            text: _text,
            onImage: _processImage,
            initialCameraLensDirection: _cameraLensDirection,
            onCameraLensDirectionChanged: (value) =>
                _cameraLensDirection = value,
          ),

          // Compteur de curls en bas
          Positioned(
            bottom: MediaQuery.of(context).viewPadding.bottom + 20,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.5),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  'Curls: ${_curlCounter.count}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }



  // Fonction qui traite chaque image capturée
  Future<void> _processImage(InputImage inputImage) async {
    if (!_canProcess || _isBusy) return;
    _isBusy = true;

    setState(() => _text = '');

    // 1️⃣ Détecte les poses
    final poses = await _poseDetector.processImage(inputImage);

    // 2️⃣ Sauvegarde le nombre précédent
    final int previousCount = _curlCounter.count;

    // 3️⃣ Met à jour le compteur
    _curlCounter.update(poses);

    // 4️⃣ Si le compteur a augmenté, prononce le nombre
    if (_curlCounter.count > previousCount) {
      await _flutterTts.speak('${_curlCounter.count}');
    }

    // 5️⃣ Dessine les landmarks si metadata dispo
    if (inputImage.metadata?.size != null &&
        inputImage.metadata?.rotation != null) {
      final painter = PosePainter(
        poses,
        inputImage.metadata!.size,
        inputImage.metadata!.rotation,
        _cameraLensDirection,
      );
      _customPaint = CustomPaint(painter: painter);
    } else {
      _customPaint = null;
    }

    _isBusy = false;
    if (mounted) setState(() {});
  }
}
