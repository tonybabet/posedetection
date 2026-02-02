import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:flutter_tts/flutter_tts.dart';

import 'detector_view.dart';
import 'painters/pose_painter.dart';  // ✅ PosePainter original non modifié
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

  final CurlCounter _curlCounter = CurlCounter();
  final FlutterTts _flutterTts = FlutterTts();

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
          // Vue de la caméra avec détection
          DetectorView(
            title: 'Pose Detector',
            customPaint: _customPaint,
            text: _text,
            onImage: _processImage,
            initialCameraLensDirection: _cameraLensDirection,
            onCameraLensDirectionChanged: (value) =>
                _cameraLensDirection = value,
          ),

          // Indicateur d'état du mouvement (en haut)
          Positioned(
            top: MediaQuery.of(context).viewPadding.top + 20,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                decoration: BoxDecoration(
                  color: _getStateColor().withOpacity(0.9),
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black26,
                      blurRadius: 8,
                      offset: Offset(0, 2),
                    ),
                  ],
                ),
                child: Text(
                  _getStateText(),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ),

          // ✅ SWITCH DE BRAS (en haut, sous l'état)
          Positioned(
            top: MediaQuery.of(context).viewPadding.top + 65,
            left: 0,
            right: 0,
            child: Center(
              child: GestureDetector(
                onTap: () {
                  setState(() {
                    _curlCounter.switchArm();
                  });
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  decoration: BoxDecoration(
                    color: _curlCounter.selectedArm == ArmSelection.left 
                        ? Colors.green.withOpacity(0.9)
                        : Colors.blue.withOpacity(0.9),
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black26,
                        blurRadius: 6,
                        offset: Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _curlCounter.selectedArm == ArmSelection.left
                            ? Icons.arrow_back
                            : Icons.arrow_forward,
                        color: Colors.white,
                        size: 16,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Bras ${_curlCounter.selectedArmText}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Icon(
                        Icons.sync,
                        color: Colors.white,
                        size: 16,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // Statut de calibration (en haut à droite)
          if (!_curlCounter.isCalibrated)
            Positioned(
              top: MediaQuery.of(context).viewPadding.top + 110,
              right: 16,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.orange.withOpacity(0.9),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  _curlCounter.calibrationStatus,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),

          // Compteur principal (en bas)
          Positioned(
            bottom: MediaQuery.of(context).viewPadding.bottom + 100,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 15),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.7),
                  borderRadius: BorderRadius.circular(25),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black38,
                      blurRadius: 10,
                      offset: Offset(0, 3),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Répétitions',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${_curlCounter.count}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 48,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Indicateur de qualité de la dernière rep
          if (_curlCounter.count > 0)
            Positioned(
              bottom: MediaQuery.of(context).viewPadding.bottom + 180,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: _getQualityColor().withOpacity(0.9),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _getQualityIcon(),
                        color: Colors.white,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _getQualityText(),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // Statistiques détaillées (en bas à gauche)
          Positioned(
            bottom: MediaQuery.of(context).viewPadding.bottom + 20,
            left: 16,
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.6),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildStatRow('⭐', _curlCounter.excellentReps, Colors.green),
                  _buildStatRow('✓', _curlCounter.bonReps, Colors.lightGreen),
                  _buildStatRow('~', _curlCounter.moyenReps, Colors.orange),
                  _buildStatRow('✗', _curlCounter.mauvaisReps, Colors.red),
                ],
              ),
            ),
          ),

          // Score de qualité global (en bas à droite)
          if (_curlCounter.count > 0)
            Positioned(
              bottom: MediaQuery.of(context).viewPadding.bottom + 20,
              right: 16,
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.6),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  children: [
                    const Text(
                      'Qualité',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${_curlCounter.qualityScore.toStringAsFixed(0)}%',
                      style: TextStyle(
                        color: _getScoreColor(_curlCounter.qualityScore),
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // Bouton reset (en haut à gauche)
          Positioned(
            top: MediaQuery.of(context).viewPadding.top + 110,
            left: 16,
            child: FloatingActionButton(
              mini: true,
              backgroundColor: Colors.red.withOpacity(0.8),
              onPressed: () {
                setState(() {
                  _curlCounter.reset();
                });
              },
              child: const Icon(Icons.refresh, size: 20),
            ),
          ),
        ],
      ),
    );
  }

  // ==================== HELPERS POUR L'AFFICHAGE ====================

  Widget _buildStatRow(String icon, int count, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Text(
            icon,
            style: TextStyle(fontSize: 16, color: color),
          ),
          const SizedBox(width: 8),
          Text(
            '$count',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  String _getStateText() {
    switch (_curlCounter.currentState) {
      case CurlState.repos:
        return 'Au repos';
      case CurlState.montee:
        return '↑ Montée';
      case CurlState.contraction:
        return '💪 Contraction';
      case CurlState.descente:
        return '↓ Descente';
    }
  }

  Color _getStateColor() {
    switch (_curlCounter.currentState) {
      case CurlState.repos:
        return Colors.blue;
      case CurlState.montee:
        return Colors.orange;
      case CurlState.contraction:
        return Colors.red;
      case CurlState.descente:
        return Colors.green;
    }
  }

  String _getQualityText() {
    switch (_curlCounter.lastRepQuality) {
      case MovementQuality.excellent:
        return 'Excellent !';
      case MovementQuality.bon:
        return 'Bon';
      case MovementQuality.moyen:
        return 'Moyen';
      case MovementQuality.mauvais:
        return 'Mauvais';
    }
  }

  IconData _getQualityIcon() {
    switch (_curlCounter.lastRepQuality) {
      case MovementQuality.excellent:
        return Icons.star;
      case MovementQuality.bon:
        return Icons.check_circle;
      case MovementQuality.moyen:
        return Icons.warning;
      case MovementQuality.mauvais:
        return Icons.error;
    }
  }

  Color _getQualityColor() {
    switch (_curlCounter.lastRepQuality) {
      case MovementQuality.excellent:
        return Colors.green;
      case MovementQuality.bon:
        return Colors.lightGreen;
      case MovementQuality.moyen:
        return Colors.orange;
      case MovementQuality.mauvais:
        return Colors.red;
    }
  }

  Color _getScoreColor(double score) {
    if (score >= 80) return Colors.green;
    if (score >= 60) return Colors.lightGreen;
    if (score >= 40) return Colors.orange;
    return Colors.red;
  }

  // ==================== TRAITEMENT DES IMAGES ====================

  Future<void> _processImage(InputImage inputImage) async {
    if (!_canProcess || _isBusy) return;
    _isBusy = true;

    setState(() => _text = '');

    try {
      // 1️⃣ Détecte les poses
      final poses = await _poseDetector.processImage(inputImage);

      // 2️⃣ Sauvegarde le nombre précédent
      final int previousCount = _curlCounter.count;

      // 3️⃣ Met à jour le compteur
      _curlCounter.update(poses);

      // 4️⃣ Si le compteur a augmenté, prononce le nombre
      if (_curlCounter.count > previousCount) {
        // Ne pas utiliser await pour ne pas bloquer la détection
        _flutterTts.speak('${_curlCounter.count}');
      }

      // 5️⃣ Dessine les landmarks avec PosePainter original
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
    } catch (e) {
      // Gestion d'erreur silencieuse - juste skip cette frame
      print('Erreur de détection: $e');
    }

    _isBusy = false;
    if (mounted) setState(() {});
  }
}
