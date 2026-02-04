import 'dart:math';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

/// Bras sélectionné manuellement
enum ArmSelection {
  left,   // Bras gauche
  right,  // Bras droit
}

/// Qualité du mouvement
enum MovementQuality {
  excellent,  // Forme parfaite
  bon,        // Forme acceptable
  moyen,      // Forme passable
  mauvais     // Triche détectée
}

class CurlCounter {
  // ==================== SÉLECTION DU BRAS ====================
  ArmSelection selectedArm = ArmSelection.right;
  
  // ==================== COMPTEURS ====================
  int count = 0;
  int excellentReps = 0;
  int bonReps = 0;
  int moyenReps = 0;
  int mauvaisReps = 0;

  // ==================== SEUILS SIMPLES (APPROCHE PRO) ====================
  
  // Angles de base (avant calibration)
  double _angleRepos = 140;         // Bras tendu (> 140° = au repos)
  double _angleContraction = 75;    // Bras plié (< 75° = contraction)
  
  // ==================== VALIDATION ====================
  final double minLikelihood = 0.75;        // 75% confiance minimum
  final int minFramesInZone = 2;            // 2 frames dans zone contraction
  final int smoothingFrames = 3;            // Lissage sur 3 frames
  
  // Détection de triche
  final double shoulderMovementThreshold = 30;
  final double elbowSwingThreshold = 40;
  final double minROM = 70;  // Amplitude minimale
  
  // ==================== ÉTAT INTERNE ====================
  bool _repCounted = false;              // Rep déjà comptée ce cycle
  int _framesInContractionZone = 0;     // Compteur frames en contraction
  MovementQuality _lastRepQuality = MovementQuality.bon;
  
  // Lissage
  final List<double> _recentAngles = [];
  final List<double> _recentShoulderY = [];
  final List<double> _recentElbowX = [];
  
  // Métriques du mouvement
  double _minAngleThisRep = 180;
  double _maxAngleThisRep = 0;
  double _maxShoulderMovement = 0;
  double _maxElbowSwing = 0;
  double _baselineShoulderY = 0;
  double _baselineElbowX = 0;
  bool _baselineSet = false;
  
  // Calibration
  bool _isCalibrated = false;
  final int calibrationReps = 3;
  final List<double> _calibrationMaxAngles = [];  // On garde seulement les MAX

  // ==================== GETTERS PUBLICS ====================
  MovementQuality get lastRepQuality => _lastRepQuality;
  bool get isCalibrated => _isCalibrated;
  
  String get calibrationStatus => _isCalibrated 
      ? 'Calibré ✓' 
      : 'Calibration: ${_calibrationMaxAngles.length}/$calibrationReps reps';
  
  String get selectedArmText {
    return selectedArm == ArmSelection.left ? 'Gauche' : 'Droit';
  }
  
  String get currentStateText {
    if (_framesInContractionZone > 0) return '💪 Contraction';
    if (_recentAngles.isNotEmpty && _recentAngles.last < _angleRepos) return '↑ Montée';
    return 'Au repos';
  }
  
  double get qualityScore {
    if (count == 0) return 0;
    return ((excellentReps + bonReps) / count * 100);
  }

  // ==================== SWITCH DE BRAS ====================
  void switchArm() {
    selectedArm = selectedArm == ArmSelection.left 
        ? ArmSelection.right 
        : ArmSelection.left;
    
    // Reset
    _recentAngles.clear();
    _recentShoulderY.clear();
    _recentElbowX.clear();
    _framesInContractionZone = 0;
    _repCounted = false;
    _baselineSet = false;
  }

  // ==================== VALIDATION DES LANDMARKS ====================
  
  bool _isLandmarkValid(PoseLandmark? landmark) {
    if (landmark == null) return false;
    if (landmark.x < 0 || landmark.y < 0) return false;
    if (landmark.x > 1e4 || landmark.y > 1e4) return false;
    
    // ✅ Vérif confiance stricte
    if (landmark.likelihood < minLikelihood) return false;
    
    return true;
  }

  bool _areAllLandmarksValid(
    PoseLandmark? shoulder,
    PoseLandmark? elbow,
    PoseLandmark? wrist
  ) {
    // Épaule et coude OBLIGATOIRES
    if (!_isLandmarkValid(shoulder)) return false;
    if (!_isLandmarkValid(elbow)) return false;
    
    // ✅ Poignet FACULTATIF
    // Si poignet invalide, on continue quand même
    if (!_isLandmarkValid(wrist)) {
      return true;  // OK sans poignet
    }
    
    // Si poignet valide, vérifier cohérence anatomique
    double shoulderToElbow = _distance(shoulder!, elbow!);
    double elbowToWrist = _distance(elbow, wrist!);
    
    if (shoulderToElbow < 50 || shoulderToElbow > 400) return false;
    if (elbowToWrist < 50 || elbowToWrist > 400) return false;
    
    double ratio = shoulderToElbow / elbowToWrist;
    if (ratio < 0.3 || ratio > 3.0) return false;
    
    return true;
  }
  
  double _distance(PoseLandmark a, PoseLandmark b) {
    return sqrt(pow(a.x - b.x, 2) + pow(a.y - b.y, 2));
  }

  // ==================== CALCUL D'ANGLE ====================
  double _calculateAngle(
    PoseLandmark shoulder,
    PoseLandmark elbow,
    PoseLandmark wrist
  ) {
    final a = _Vector2D(shoulder.x - elbow.x, shoulder.y - elbow.y);
    final b = _Vector2D(wrist.x - elbow.x, wrist.y - elbow.y);
    
    double dot = a.dx * b.dx + a.dy * b.dy;
    double magA = sqrt(a.dx * a.dx + a.dy * a.dy);
    double magB = sqrt(b.dx * b.dx + b.dy * b.dy);
    
    if (magA == 0 || magB == 0) return 0;
    
    double cosAngle = (dot / (magA * magB)).clamp(-1.0, 1.0);
    return acos(cosAngle) * 180 / pi;
  }

  // ==================== LISSAGE ====================
  double _addAndSmooth(List<double> list, double value) {
    list.add(value);
    if (list.length > smoothingFrames) {
      list.removeAt(0);
    }
    
    if (list.length < smoothingFrames) {
      return value;
    }
    
    return list.reduce((a, b) => a + b) / list.length;
  }

  // ==================== DÉTECTION DE TRICHE ====================
  void _updateCheatDetection(double shoulderY, double elbowX, double angle) {
    double smoothedShoulderY = _addAndSmooth(_recentShoulderY, shoulderY);
    double smoothedElbowX = _addAndSmooth(_recentElbowX, elbowX);
    
    // Établir baseline au repos
    if (!_baselineSet && angle > _angleRepos) {
      _baselineShoulderY = smoothedShoulderY;
      _baselineElbowX = smoothedElbowX;
      _baselineSet = true;
    }
    
    if (_baselineSet) {
      double shoulderMovement = (smoothedShoulderY - _baselineShoulderY).abs();
      double elbowSwing = (smoothedElbowX - _baselineElbowX).abs();
      
      _maxShoulderMovement = max(_maxShoulderMovement, shoulderMovement);
      _maxElbowSwing = max(_maxElbowSwing, elbowSwing);
    }
  }

  // ==================== ÉVALUATION DE LA QUALITÉ ====================
  MovementQuality _evaluateRepQuality() {
    int penalties = 0;
    
    double rom = _maxAngleThisRep - _minAngleThisRep;
    if (rom < minROM) penalties += 2;
    else if (rom < minROM + 20) penalties += 1;
    
    if (_maxShoulderMovement > shoulderMovementThreshold * 1.5) penalties += 2;
    else if (_maxShoulderMovement > shoulderMovementThreshold) penalties += 1;
    
    if (_maxElbowSwing > elbowSwingThreshold * 1.5) penalties += 2;
    else if (_maxElbowSwing > elbowSwingThreshold) penalties += 1;
    
    if (penalties == 0) return MovementQuality.excellent;
    if (penalties == 1) return MovementQuality.bon;
    if (penalties == 2) return MovementQuality.moyen;
    return MovementQuality.mauvais;
  }

  // ==================== CALIBRATION ====================
  void _calibrateFromRep() {
    // On enregistre seulement l'angle MAX (bras tendu)
    _calibrationMaxAngles.add(_maxAngleThisRep);
    
    if (_calibrationMaxAngles.length >= calibrationReps) {
      double avgMax = _calibrationMaxAngles.reduce((a, b) => a + b) / calibrationReps;
      
      // Calibrer seulement l'angle de repos (bras tendu)
      _angleRepos = avgMax - 20;  // S'adapte à TON extension max
      
      _isCalibrated = true;
    }
  }

  // ==================== COMPTAGE DES REPS (LOGIQUE SIMPLE) ====================
  void _completeRep() {
    _lastRepQuality = _evaluateRepQuality();
    
    count++;
    switch (_lastRepQuality) {
      case MovementQuality.excellent:
        excellentReps++;
        break;
      case MovementQuality.bon:
        bonReps++;
        break;
      case MovementQuality.moyen:
        moyenReps++;
        break;
      case MovementQuality.mauvais:
        mauvaisReps++;
        break;
    }
    
    if (!_isCalibrated && _lastRepQuality != MovementQuality.mauvais) {
      _calibrateFromRep();
    }
    
    _repCounted = true;
  }

  void _resetRepMetrics() {
    _minAngleThisRep = 180;
    _maxAngleThisRep = 0;
    _maxShoulderMovement = 0;
    _maxElbowSwing = 0;
    _baselineSet = false;
  }

  // ==================== FONCTION PRINCIPALE D'UPDATE (SIMPLIFIÉE) ====================
  
  void update(List<Pose> poses) {
    if (poses.isEmpty) return;
    
    final pose = poses.first;
    
    // Récupérer landmarks du bras sélectionné
    PoseLandmark? shoulder;
    PoseLandmark? elbow;
    PoseLandmark? wrist;
    
    if (selectedArm == ArmSelection.left) {
      shoulder = pose.landmarks[PoseLandmarkType.leftShoulder];
      elbow = pose.landmarks[PoseLandmarkType.leftElbow];
      wrist = pose.landmarks[PoseLandmarkType.leftWrist];
    } else {
      shoulder = pose.landmarks[PoseLandmarkType.rightShoulder];
      elbow = pose.landmarks[PoseLandmarkType.rightElbow];
      wrist = pose.landmarks[PoseLandmarkType.rightWrist];
    }
    
    // ✅ VALIDATION STRICTE (likelihood + anatomie)
    if (!_areAllLandmarksValid(shoulder, elbow, wrist)) {
      return;
    }
    
    // Calcul angle
    double angle = _calculateAngle(shoulder!, elbow!, wrist!);
    
    // ✅ LISSAGE ROBUSTE
    double smoothedAngle = _addAndSmooth(_recentAngles, angle);
    
    if (_recentAngles.length < smoothingFrames) {
      return;  // Attendre d'avoir assez de frames
    }
    
    // Suivre les extremums
    _minAngleThisRep = min(_minAngleThisRep, smoothedAngle);
    _maxAngleThisRep = max(_maxAngleThisRep, smoothedAngle);
    
    // Détection de triche
    _updateCheatDetection(shoulder.y, elbow.x, smoothedAngle);
    
    // ==================== LOGIQUE SIMPLE (APPROCHE PRO) ====================
    
    // 1️⃣ BRAS AU REPOS (> angleRepos) → Reset pour nouvelle rep
    if (smoothedAngle > _angleRepos) {
      _framesInContractionZone = 0;
      _repCounted = false;
      _resetRepMetrics();
    }
    
    // 2️⃣ DANS ZONE DE CONTRACTION (< angleContraction)
    if (smoothedAngle < _angleContraction) {
      _framesInContractionZone++;
      
      // 3️⃣ COMPTAGE après minFramesInZone frames
      if (_framesInContractionZone >= minFramesInZone && !_repCounted) {
        _completeRep();  // ✅ COMPTE !
      }
    } else {
      // Hors zone de contraction → reset compteur
      if (_framesInContractionZone > 0 && _framesInContractionZone < minFramesInZone) {
        _framesInContractionZone = 0;  // Pas resté assez longtemps
      }
    }
  }

  // ==================== RESET PUBLIC ====================
  void reset() {
    count = 0;
    excellentReps = 0;
    bonReps = 0;
    moyenReps = 0;
    mauvaisReps = 0;
    _repCounted = false;
    _framesInContractionZone = 0;
    _recentAngles.clear();
    _recentShoulderY.clear();
    _recentElbowX.clear();
    _resetRepMetrics();
  }

  void resetCalibration() {
    _isCalibrated = false;
    _calibrationMaxAngles.clear();
    _angleContraction = 75;
    _angleRepos = 140;
  }
}

// ==================== CLASSE HELPER ====================
class _Vector2D {
  final double dx;
  final double dy;
  _Vector2D(this.dx, this.dy);
}
