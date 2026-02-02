import 'dart:math';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

/// Bras sélectionné manuellement
enum ArmSelection {
  left, // Bras gauche
  right, // Bras droit
}

/// États du mouvement de curl
enum CurlState {
  repos, // Bras tendu, au repos
  montee, // En train de plier le bras
  contraction, // Bras complètement plié (pic de contraction)
  descente // En train de redescendre
}

/// Qualité du mouvement
enum MovementQuality {
  excellent, // Forme parfaite
  bon, // Forme acceptable
  moyen, // Forme passable avec petites erreurs
  mauvais // Triche détectée ou mouvement incorrect
}

class CurlCounter {
  // ==================== SÉLECTION DU BRAS ====================
  ArmSelection selectedArm = ArmSelection.right; // Bras par défaut

  // ==================== COMPTEURS ====================
  int count = 0;
  int excellentReps = 0;
  int bonReps = 0;
  int moyenReps = 0;
  int mauvaisReps = 0;

  // ==================== ÉTAT INTERNE ====================
  CurlState _currentState = CurlState.repos;
  MovementQuality _lastRepQuality = MovementQuality.bon;
  bool _repCountedThisCycle = false;

  // ==================== LISSAGE ROBUSTE ====================
  final int smoothingFrames =
      3; // ✅ RÉDUIT : Moyenne sur 3 frames (plus rapide)
  final List<double> _recentAngles = [];
  final List<double> _recentShoulderY = [];
  final List<double> _recentElbowX = [];

  // ==================== CALIBRATION ====================
  bool _isCalibrated = false;
  final int calibrationReps = 3;
  final List<double> _calibrationMinAngles = [];
  final List<double> _calibrationMaxAngles = [];

  // Angles dynamiques (s'adaptent à l'utilisateur)
  double _minAngle = 50; // ✅ MODIFIÉ : Compte plus tôt (bras moins plié)
  double _maxAngle = 160; // Valeur par défaut

  // ==================== SEUILS DE VALIDATION RENFORCÉS ====================
  final double minROM = 70; // Amplitude minimale
  final double shoulderMovementThreshold = 30; // Mouvement d'épaule max
  final double elbowSwingThreshold = 40; // Mouvement de coude max

  // ✅ ZONE NEUTRE (hystérésis pour éviter oscillations)
  final double transitionZone = 20; // Augmenté de 15 à 20

  // ✅ VALIDATION MULTI-FRAMES (doit rester X frames dans un état)
  final int minFramesPerState = 2; // ✅ ULTRA-RAPIDE : 2 frames seulement
  final int maxFramesInState = 90; // Timeout (3 sec à 30fps)

  // ✅ SEUIL DE CONFIANCE (likelihood)
  final double minLikelihood = 0.75; // 75% de confiance minimum (strict)

  // ==================== TEMPS ====================
  int _framesSinceStateChange = 0;

  // ==================== MÉTRIQUES DU MOUVEMENT ACTUEL ====================
  double _minAngleThisRep = 180;
  double _maxAngleThisRep = 0;
  double _maxShoulderMovement = 0;
  double _maxElbowSwing = 0;
  double _baselineShoulderY = 0;
  double _baselineElbowX = 0;

  // ==================== GETTERS PUBLICS ====================
  CurlState get currentState => _currentState;
  MovementQuality get lastRepQuality => _lastRepQuality;
  bool get isCalibrated => _isCalibrated;
  String get calibrationStatus => _isCalibrated
      ? 'Calibré ✓'
      : 'Calibration: ${_calibrationMinAngles.length}/$calibrationReps reps';

  String get selectedArmText {
    return selectedArm == ArmSelection.left ? 'Gauche' : 'Droit';
  }

  /// Retourne le pourcentage de reps de bonne qualité
  double get qualityScore {
    if (count == 0) return 0;
    return ((excellentReps + bonReps) / count * 100);
  }

  // ==================== SWITCH DE BRAS ====================
  void switchArm() {
    if (_currentState == CurlState.repos) {
      selectedArm = selectedArm == ArmSelection.left
          ? ArmSelection.right
          : ArmSelection.left;

      // Reset les historiques de lissage
      _recentAngles.clear();
      _recentShoulderY.clear();
      _recentElbowX.clear();
    }
  }

  // ==================== VALIDATION DES LANDMARKS (RENFORCÉE) ====================

  /// ✅ Vérification stricte avec likelihood
  bool _isLandmarkValid(PoseLandmark? landmark) {
    if (landmark == null) return false;

    // Vérifier les coordonnées
    if (landmark.x < 0 || landmark.y < 0) return false;
    if (landmark.x > 1e4 || landmark.y > 1e4) return false;

    // ✅ CRITIQUE : Vérifier le score de confiance (likelihood)
    // Seuil strict à 75% pour éliminer les faux positifs
    if (landmark.likelihood < minLikelihood) return false;

    return true;
  }

  /// ✅ Validation complète avec vérifications anatomiques
  bool _areAllLandmarksValid(
      PoseLandmark? shoulder, PoseLandmark? elbow, PoseLandmark? wrist) {
    if (!_isLandmarkValid(shoulder)) return false;
    if (!_isLandmarkValid(elbow)) return false;
    if (!_isLandmarkValid(wrist)) return true;

    // ✅ Vérifier la cohérence anatomique
    double shoulderToElbow = _distance(shoulder!, elbow!);
    double elbowToWrist = _distance(elbow, wrist!);

    // Distances physiologiques réalistes (en pixels)
    if (shoulderToElbow < 50 || shoulderToElbow > 400) return false;
    if (elbowToWrist < 50 || elbowToWrist > 400) return false;

    // Vérifier que le ratio est cohérent
    double ratio = shoulderToElbow / elbowToWrist;
    if (ratio < 0.3 || ratio > 3.0) return false;

    return true;
  }

  double _distance(PoseLandmark a, PoseLandmark b) {
    return sqrt(pow(a.x - b.x, 2) + pow(a.y - b.y, 2));
  }

  // ==================== CALCUL D'ANGLE ====================
  double _calculateAngle(
      PoseLandmark shoulder, PoseLandmark elbow, PoseLandmark wrist) {
    final a = _Vector2D(shoulder.x - elbow.x, shoulder.y - elbow.y);
    final b = _Vector2D(wrist.x - elbow.x, wrist.y - elbow.y);

    double dot = a.dx * b.dx + a.dy * b.dy;
    double magA = sqrt(a.dx * a.dx + a.dy * a.dy);
    double magB = sqrt(b.dx * b.dx + b.dy * b.dy);

    if (magA == 0 || magB == 0) return 0;

    double cosAngle = (dot / (magA * magB)).clamp(-1.0, 1.0);
    return acos(cosAngle) * 180 / pi;
  }

  // ==================== LISSAGE ROBUSTE ====================

  /// ✅ SUPER IMPORTANT : Lissage par moyenne mobile
  double _addAndSmooth(List<double> list, double value) {
    list.add(value);
    if (list.length > smoothingFrames) {
      list.removeAt(0);
    }

    // Ne lisser que si on a assez de frames
    if (list.length < smoothingFrames) {
      return value; // Pas assez de données, retourner la valeur brute
    }

    return list.reduce((a, b) => a + b) / list.length;
  }

  // ==================== DÉTECTION DE TRICHE ====================
  void _updateCheatDetection(double shoulderY, double elbowX) {
    double smoothedShoulderY = _addAndSmooth(_recentShoulderY, shoulderY);
    double smoothedElbowX = _addAndSmooth(_recentElbowX, elbowX);

    if (_currentState == CurlState.repos && _framesSinceStateChange < 5) {
      _baselineShoulderY = smoothedShoulderY;
      _baselineElbowX = smoothedElbowX;
    }

    double shoulderMovement = (smoothedShoulderY - _baselineShoulderY).abs();
    double elbowSwing = (smoothedElbowX - _baselineElbowX).abs();

    _maxShoulderMovement = max(_maxShoulderMovement, shoulderMovement);
    _maxElbowSwing = max(_maxElbowSwing, elbowSwing);
  }

  // ==================== ÉVALUATION DE LA QUALITÉ ====================
  MovementQuality _evaluateRepQuality() {
    int penalties = 0;

    double rom = _maxAngleThisRep - _minAngleThisRep;
    if (rom < minROM)
      penalties += 2;
    else if (rom < minROM + 20) penalties += 1;

    if (_maxShoulderMovement > shoulderMovementThreshold * 1.5)
      penalties += 2;
    else if (_maxShoulderMovement > shoulderMovementThreshold) penalties += 1;

    if (_maxElbowSwing > elbowSwingThreshold * 1.5)
      penalties += 2;
    else if (_maxElbowSwing > elbowSwingThreshold) penalties += 1;

    if (penalties == 0) return MovementQuality.excellent;
    if (penalties == 1) return MovementQuality.bon;
    if (penalties == 2) return MovementQuality.moyen;
    return MovementQuality.mauvais;
  }

  // ==================== CALIBRATION ====================
  void _calibrateFromRep() {
    _calibrationMinAngles.add(_minAngleThisRep);
    _calibrationMaxAngles.add(_maxAngleThisRep);

    if (_calibrationMinAngles.length >= calibrationReps) {
      double avgMin =
          _calibrationMinAngles.reduce((a, b) => a + b) / calibrationReps;
      double avgMax =
          _calibrationMaxAngles.reduce((a, b) => a + b) / calibrationReps;

      _minAngle = avgMin - 10;
      _maxAngle = avgMax + 10;

      _isCalibrated = true;
    }
  }

  // ==================== MACHINE À ÉTATS (AVEC ZONE NEUTRE) ====================

  /// ✅ Validation multi-frames : doit rester minFramesPerState dans un état
  void _updateState(double smoothedAngle) {
    _framesSinceStateChange++;

    // Timeout de sécurité
    if (_framesSinceStateChange > maxFramesInState) {
      _resetRep();
      return;
    }

    CurlState previousState = _currentState;

    switch (_currentState) {
      case CurlState.repos:
        // ✅ Transition : Repos → Montée (avec zone neutre)
        if (smoothedAngle < _maxAngle - transitionZone &&
            _framesSinceStateChange > minFramesPerState) {
          _currentState = CurlState.montee;
          _resetRepMetrics();
          _repCountedThisCycle = false;
        }
        break;

      case CurlState.montee:
        // ✅ Transition : Montée → Contraction (avec zone neutre)
        if (smoothedAngle < _minAngle + transitionZone &&
            _framesSinceStateChange > minFramesPerState) {
          _currentState = CurlState.contraction;
        }
        // Retour : Montée → Repos (mouvement annulé)
        else if (smoothedAngle > _maxAngle - transitionZone &&
            _framesSinceStateChange > minFramesPerState) {
          _resetRep();
        }
        break;

      case CurlState.contraction:
        // ✅ COMPTAGE ICI - dès qu'on atteint la contraction !
        if (_framesSinceStateChange == minFramesPerState &&
            !_repCountedThisCycle) {
          _completeRep();
          _repCountedThisCycle = true;
        }

        // ✅ Transition : Contraction → Descente (avec zone neutre)
        if (smoothedAngle > _minAngle + transitionZone &&
            _framesSinceStateChange > minFramesPerState) {
          _currentState = CurlState.descente;
        }
        break;

      case CurlState.descente:
        // ✅ Transition : Descente → Repos (avec zone neutre)
        if (smoothedAngle > _maxAngle - transitionZone &&
            _framesSinceStateChange > minFramesPerState) {
          _resetRep();
        }
        // Retour : Descente → Contraction (pas descendu assez)
        else if (smoothedAngle < _minAngle + transitionZone) {
          _currentState = CurlState.contraction;
          _framesSinceStateChange = 0;
        }
        break;
    }

    // Reset du compteur de frames si changement d'état
    if (_currentState != previousState) {
      _framesSinceStateChange = 0;
    }
  }

  // ==================== GESTION DES REPS ====================
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
  }

  void _resetRepMetrics() {
    _minAngleThisRep = 180;
    _maxAngleThisRep = 0;
    _maxShoulderMovement = 0;
    _maxElbowSwing = 0;
  }

  void _resetRep() {
    _currentState = CurlState.repos;
    _framesSinceStateChange = 0;
    _resetRepMetrics();
    _repCountedThisCycle = false;
  }

  // ==================== FONCTION PRINCIPALE D'UPDATE ====================

  /// ✅ Version simplifiée : utilise UNIQUEMENT le bras sélectionné
  void update(List<Pose> poses) {
    if (poses.isEmpty) return;

    final pose = poses.first;

    // ✅ Récupérer UNIQUEMENT les landmarks du bras sélectionné
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

    // ✅ Validation stricte (likelihood + anatomie)
    if (!_areAllLandmarksValid(shoulder, elbow, wrist)) {
      return; // Ignorer cette frame si pas valide
    }

    // Calcul de l'angle
    double angle = _calculateAngle(shoulder!, elbow!, wrist!);

    // ✅ LISSAGE ROBUSTE (moyenne sur 5 frames)
    double smoothedAngle = _addAndSmooth(_recentAngles, angle);

    // Ne continuer que si on a assez de frames pour un lissage fiable
    if (_recentAngles.length < smoothingFrames) {
      return; // Attendre d'avoir 5 frames
    }

    // Suivre les extremums
    _minAngleThisRep = min(_minAngleThisRep, smoothedAngle);
    _maxAngleThisRep = max(_maxAngleThisRep, smoothedAngle);

    // Détection de triche
    _updateCheatDetection(shoulder.y, elbow.x);

    // Machine à états
    _updateState(smoothedAngle);
  }

  // ==================== RESET PUBLIC ====================
  void reset() {
    count = 0;
    excellentReps = 0;
    bonReps = 0;
    moyenReps = 0;
    mauvaisReps = 0;
    _resetRep();
    _recentAngles.clear();
    _recentShoulderY.clear();
    _recentElbowX.clear();
  }

  void resetCalibration() {
    _isCalibrated = false;
    _calibrationMinAngles.clear();
    _calibrationMaxAngles.clear();
    _minAngle = 50; // ✅ MODIFIÉ
    _maxAngle = 160;
  }
}

// ==================== CLASSE HELPER ====================
class _Vector2D {
  final double dx;
  final double dy;
  _Vector2D(this.dx, this.dy);
}
