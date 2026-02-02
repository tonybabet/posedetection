import 'dart:math';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

class CurlCounter {
  int count = 0;
  bool _isCurling = false;

  /// Angle minimum et maximum pour détecter un curl
  final double minAngle = 50; // bras plié
  final double maxAngle = 160; // bras tendu

  /// Lissage avec moyenne mobile
  final int smoothingFrames = 5;
  final List<double> _recentAngles = [];

  /// Vérifie que les landmarks sont plausibles avant de calculer l'angle
  bool _isLandmarkValid(PoseLandmark? landmark, PoseLandmark? shoulder, PoseLandmark? wrist) {
    if (landmark == null || shoulder == null || wrist == null) return false;
    if (landmark.x < 0 || landmark.y < 0 || landmark.x > 1e4 || landmark.y > 1e4) return false;
    double dist = sqrt(pow(shoulder.x - wrist.x, 2) + pow(shoulder.y - wrist.y, 2));
    if (dist < 20 || dist > 1000) return false; // distance trop courte ou trop grande
    return true;
  }

  /// Calcule l'angle au niveau du coude
  double _calculateAngle(PoseLandmark shoulder, PoseLandmark elbow, PoseLandmark wrist) {
    final a = Offset(shoulder.x - elbow.x, shoulder.y - elbow.y);
    final b = Offset(wrist.x - elbow.x, wrist.y - elbow.y);
    double dot = a.dx * b.dx + a.dy * b.dy;
    double magA = sqrt(a.dx * a.dx + a.dy * a.dy);
    double magB = sqrt(b.dx * b.dx + b.dy * b.dy);
    double cosAngle = dot / (magA * magB);
    cosAngle = cosAngle.clamp(-1.0, 1.0);
    return acos(cosAngle) * 180 / pi;
  }

  /// Appelle cette fonction à chaque frame
  void update(List<Pose> poses) {
    if (poses.isEmpty) return;
    final pose = poses.first; // tu peux changer pour bras droit ou gauche

    final shoulder = pose.landmarks[PoseLandmarkType.rightShoulder];
    final elbow = pose.landmarks[PoseLandmarkType.rightElbow];
    final wrist = pose.landmarks[PoseLandmarkType.rightWrist];

    if (!_isLandmarkValid(elbow, shoulder, wrist)) return;

    double angle = _calculateAngle(shoulder!, elbow!, wrist!);

    // Ajoute à la liste des angles récents
    _recentAngles.add(angle);
    if (_recentAngles.length > smoothingFrames) {
      _recentAngles.removeAt(0);
    }

    // Moyenne mobile
    double smoothedAngle = _recentAngles.reduce((a, b) => a + b) / _recentAngles.length;

    // Détecte le curl sur l’angle lissé
    if (!_isCurling && smoothedAngle < minAngle) {
      _isCurling = true;
    } else if (_isCurling && smoothedAngle > maxAngle) {
      count++;
      _isCurling = false;
    }
  }
}

/// Classe helper pour les calculs
class Offset {
  final double dx;
  final double dy;
  Offset(this.dx, this.dy);
}
