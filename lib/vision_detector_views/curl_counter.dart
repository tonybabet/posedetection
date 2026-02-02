import 'dart:math';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

/// Bras actif détecté
enum ActiveArm {
  none,    // Aucun bras détecté
  left,    // Bras gauche
  right,   // Bras droit
  both     // Les deux bras (détection simultanée)
}

/// États du mouvement de curl
enum CurlState {
  repos,        // Bras tendu, au repos
  montee,       // En train de plier le bras
  contraction,  // Bras complètement plié (pic de contraction)
  descente      // En train de redescendre
}

/// Qualité du mouvement
enum MovementQuality {
  excellent,  // Forme parfaite
  bon,        // Forme acceptable
  moyen,      // Forme passable avec petites erreurs
  mauvais     // Triche détectée ou mouvement incorrect
}

class CurlCounter {
  // ==================== COMPTEURS ====================
  int count = 0;
  int excellentReps = 0;
  int bonReps = 0;
  int moyenReps = 0;
  int mauvaisReps = 0;

  // ==================== ÉTAT INTERNE ====================
  CurlState _currentState = CurlState.repos;
  MovementQuality _lastRepQuality = MovementQuality.bon;
  bool _repCountedThisCycle = false;  // Flag pour éviter double comptage
  
  // Détection automatique du bras actif
  ActiveArm _activeArm = ActiveArm.none;
  final List<double> _recentLeftAngles = [];
  final List<double> _recentRightAngles = [];
  int _framesWithoutMovement = 0;
  
  // ==================== LISSAGE ====================
  final int smoothingFrames = 5;
  final List<double> _recentAngles = [];
  final List<double> _recentShoulderY = [];
  final List<double> _recentElbowX = [];
  
  // ==================== CALIBRATION ====================
  bool _isCalibrated = false;
  final int calibrationReps = 3;
  final List<double> _calibrationMinAngles = [];
  final List<double> _calibrationMaxAngles = [];
  
  // Angles dynamiques (s'adaptent à l'utilisateur)
  double _minAngle = 40;   // Valeur par défaut - sera calibrée
  double _maxAngle = 160;  // Valeur par défaut - sera calibrée
  
  // ==================== SEUILS DE VALIDATION ====================
  final double minROM = 70;              // Amplitude minimale requise (en degrés)
  final double shoulderMovementThreshold = 30;  // Mouvement d'épaule max toléré (pixels)
  final double elbowSwingThreshold = 40;        // Mouvement de coude max toléré (pixels)
  
  // Zones de transition (hystérésis pour éviter le flicker)
  final double transitionZone = 15;      // Zone tampon pour les transitions
  
  // ==================== TEMPS ====================
  int _framesSinceStateChange = 0;
  final int minFramesPerState = 3;       // Frames minimum dans un état avant changement
  final int maxFramesInState = 60;       // Timeout (2 sec à 30fps)
  
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
  ActiveArm get activeArm => _activeArm;
  bool get isCalibrated => _isCalibrated;
  String get calibrationStatus => _isCalibrated 
      ? 'Calibré ✓' 
      : 'Calibration: ${_calibrationMinAngles.length}/$calibrationReps reps';
  
  String get activeArmText {
    switch (_activeArm) {
      case ActiveArm.left:
        return '← Gauche';
      case ActiveArm.right:
        return 'Droit →';
      case ActiveArm.both:
        return '↔ Les deux';
      case ActiveArm.none:
        return 'Aucun';
    }
  }
  
  /// Retourne le pourcentage de reps de bonne qualité
  double get qualityScore {
    if (count == 0) return 0;
    return ((excellentReps + bonReps) / count * 100);
  }

  // ==================== DÉTECTION AUTOMATIQUE DU BRAS ====================
  ActiveArm _detectActiveArm(
    double? leftAngle,
    double? rightAngle,
    bool leftHighConfidence,
    bool rightHighConfidence,
  ) {
    // Si on est déjà dans un mouvement, garder le même bras
    if (_currentState != CurlState.repos) {
      return _activeArm;
    }
    
    // ✅ NOUVEAU : Prioriser les bras avec haute confiance
    // Si un seul bras est valide ET a une bonne confiance, utiliser celui-là
    if (!leftHighConfidence && rightHighConfidence && rightAngle != null) {
      return ActiveArm.right;
    }
    if (!rightHighConfidence && leftHighConfidence && leftAngle != null) {
      return ActiveArm.left;
    }
    if (!leftHighConfidence && !rightHighConfidence) {
      return ActiveArm.none;
    }
    
    // Si les deux bras sont valides, analyser le mouvement
    if (leftAngle == null || rightAngle == null) {
      return ActiveArm.none;
    }
    
    // Ajouter aux historiques
    _recentLeftAngles.add(leftAngle);
    _recentRightAngles.add(rightAngle);
    
    // Garder seulement les dernières frames
    if (_recentLeftAngles.length > smoothingFrames) {
      _recentLeftAngles.removeAt(0);
    }
    if (_recentRightAngles.length > smoothingFrames) {
      _recentRightAngles.removeAt(0);
    }
    
    // Besoin de quelques frames pour analyser
    if (_recentLeftAngles.length < smoothingFrames) {
      return ActiveArm.none;
    }
    
    // Calculer la variation d'angle (mouvement)
    double leftVariation = _calculateVariation(_recentLeftAngles);
    double rightVariation = _calculateVariation(_recentRightAngles);
    
    // ✅ AUGMENTÉ : Seuil de mouvement plus élevé pour éviter les faux positifs
    const double movementThreshold = 15.0; // Avant: 10.0
    
    bool leftMoving = leftVariation > movementThreshold && leftHighConfidence;
    bool rightMoving = rightVariation > movementThreshold && rightHighConfidence;
    
    // Déterminer le bras actif
    if (leftMoving && rightMoving) {
      // Les deux bras bougent - prendre celui qui bouge le plus
      return leftVariation > rightVariation ? ActiveArm.left : ActiveArm.right;
    } else if (leftMoving) {
      return ActiveArm.left;
    } else if (rightMoving) {
      return ActiveArm.right;
    } else {
      // Aucun mouvement détecté
      _framesWithoutMovement++;
      // ✅ RÉDUIT : Reset plus rapide quand pas de mouvement
      if (_framesWithoutMovement > 15) { // Avant: 30
        return ActiveArm.none;
      }
      return _activeArm; // Garder le dernier bras actif
    }
  }
  
  // Calculer la variation (écart-type) d'une liste d'angles
  double _calculateVariation(List<double> angles) {
    if (angles.length < 2) return 0;
    
    double mean = angles.reduce((a, b) => a + b) / angles.length;
    double variance = angles
        .map((angle) => pow(angle - mean, 2))
        .reduce((a, b) => a + b) / angles.length;
    
    return sqrt(variance);
  }

  // ==================== VALIDATION DES LANDMARKS ====================
  bool _isLandmarkValid(PoseLandmark? landmark) {
    if (landmark == null) return false;
    
    // Vérifier les coordonnées
    if (landmark.x < 0 || landmark.y < 0) return false;
    if (landmark.x > 1e4 || landmark.y > 1e4) return false;
    
    // ✅ NOUVEAU : Vérifier le score de confiance (likelihood)
    // Si le landmark est hors champ, ML Kit donne un score très bas
    // Seuil recommandé : 0.5 (50% de confiance minimum)
    if (landmark.likelihood < 0.5) return false;
    
    return true;
  }

  bool _areAllLandmarksValid(
    PoseLandmark? shoulder,
    PoseLandmark? elbow,
    PoseLandmark? wrist
  ) {
    if (!_isLandmarkValid(shoulder)) return false;
    if (!_isLandmarkValid(elbow)) return false;
    if (!_isLandmarkValid(wrist)) return false;
    
    // ✅ NOUVEAU : Vérifier aussi la cohérence anatomique
    // Les landmarks doivent être à une distance raisonnable les uns des autres
    double shoulderToElbow = _distance(shoulder!, elbow!);
    double elbowToWrist = _distance(elbow, wrist!);
    
    // Distances physiologiques réalistes (en pixels)
    // Avant-bras et bras font généralement entre 50 et 400 pixels
    if (shoulderToElbow < 50 || shoulderToElbow > 400) return false;
    if (elbowToWrist < 50 || elbowToWrist > 400) return false;
    
    // Vérifier que le ratio est cohérent (le bras n'est pas 5x plus long que l'avant-bras)
    double ratio = shoulderToElbow / elbowToWrist;
    if (ratio < 0.3 || ratio > 3.0) return false;
    
    return true;
  }
  
  // Helper pour calculer la distance entre deux landmarks
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
    return list.reduce((a, b) => a + b) / list.length;
  }

  // ==================== DÉTECTION DE TRICHE ====================
  void _updateCheatDetection(double shoulderY, double elbowX) {
    // Lisse les positions
    double smoothedShoulderY = _addAndSmooth(_recentShoulderY, shoulderY);
    double smoothedElbowX = _addAndSmooth(_recentElbowX, elbowX);
    
    // Établir la baseline au début du mouvement
    if (_currentState == CurlState.repos && _framesSinceStateChange < 5) {
      _baselineShoulderY = smoothedShoulderY;
      _baselineElbowX = smoothedElbowX;
    }
    
    // Mesurer les déviations
    double shoulderMovement = (smoothedShoulderY - _baselineShoulderY).abs();
    double elbowSwing = (smoothedElbowX - _baselineElbowX).abs();
    
    // Garder le maximum
    _maxShoulderMovement = max(_maxShoulderMovement, shoulderMovement);
    _maxElbowSwing = max(_maxElbowSwing, elbowSwing);
  }

  // ==================== ÉVALUATION DE LA QUALITÉ ====================
  MovementQuality _evaluateRepQuality() {
    int penalties = 0;
    
    // Vérifier l'amplitude de mouvement
    double rom = _maxAngleThisRep - _minAngleThisRep;
    if (rom < minROM) penalties += 2; // Pénalité majeure
    else if (rom < minROM + 20) penalties += 1; // Pénalité mineure
    
    // Vérifier le mouvement d'épaule
    if (_maxShoulderMovement > shoulderMovementThreshold * 1.5) penalties += 2;
    else if (_maxShoulderMovement > shoulderMovementThreshold) penalties += 1;
    
    // Vérifier le swing du coude
    if (_maxElbowSwing > elbowSwingThreshold * 1.5) penalties += 2;
    else if (_maxElbowSwing > elbowSwingThreshold) penalties += 1;
    
    // Déterminer la qualité
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
      // Calculer les moyennes
      double avgMin = _calibrationMinAngles.reduce((a, b) => a + b) / calibrationReps;
      double avgMax = _calibrationMaxAngles.reduce((a, b) => a + b) / calibrationReps;
      
      // Appliquer avec une marge de sécurité
      _minAngle = avgMin - 10;  // Un peu plus bas que la moyenne
      _maxAngle = avgMax + 10;  // Un peu plus haut que la moyenne
      
      _isCalibrated = true;
    }
  }

  // ==================== MACHINE À ÉTATS ====================
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
        // Transition : Repos → Montée
        if (smoothedAngle < _maxAngle - transitionZone && 
            _framesSinceStateChange > minFramesPerState) {
          _currentState = CurlState.montee;
          _resetRepMetrics();
          _repCountedThisCycle = false;  // Reset du flag pour la nouvelle rep
        }
        break;
        
      case CurlState.montee:
        // Transition : Montée → Contraction
        if (smoothedAngle < _minAngle + transitionZone && 
            _framesSinceStateChange > minFramesPerState) {
          _currentState = CurlState.contraction;
        }
        // Retour : Montée → Repos (mouvement annulé)
        else if (smoothedAngle > _maxAngle - transitionZone) {
          _resetRep();
        }
        break;
        
      case CurlState.contraction:
        // ✅ COMPTAGE ICI - dès qu'on atteint la contraction !
        // Compter une seule fois quand on entre dans cet état
        if (_framesSinceStateChange == minFramesPerState && !_repCountedThisCycle) {
          _completeRep();  // Compte la rep immédiatement
          _repCountedThisCycle = true;  // Marquer comme comptée
        }
        
        // Transition : Contraction → Descente
        if (smoothedAngle > _minAngle + transitionZone && 
            _framesSinceStateChange > minFramesPerState) {
          _currentState = CurlState.descente;
        }
        break;
        
      case CurlState.descente:
        // Transition : Descente → Repos (retour position initiale)
        if (smoothedAngle > _maxAngle - transitionZone && 
            _framesSinceStateChange > minFramesPerState) {
          _resetRep();  // Reset complet pour la prochaine rep
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
    // Évaluer la qualité
    _lastRepQuality = _evaluateRepQuality();
    
    // Incrémenter le compteur approprié
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
    
    // Calibration si nécessaire
    if (!_isCalibrated && _lastRepQuality != MovementQuality.mauvais) {
      _calibrateFromRep();
    }
    
    // NE PAS reset ici - on continue la descente
    // Le reset se fera à la fin de la descente
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
    _repCountedThisCycle = false;  // Reset du flag
  }

  // ==================== FONCTION PRINCIPALE D'UPDATE ====================
  void update(List<Pose> poses) {
    if (poses.isEmpty) return;
    
    final pose = poses.first;
    
    // Récupérer les landmarks des DEUX bras
    final leftShoulder = pose.landmarks[PoseLandmarkType.leftShoulder];
    final leftElbow = pose.landmarks[PoseLandmarkType.leftElbow];
    final leftWrist = pose.landmarks[PoseLandmarkType.leftWrist];
    
    final rightShoulder = pose.landmarks[PoseLandmarkType.rightShoulder];
    final rightElbow = pose.landmarks[PoseLandmarkType.rightElbow];
    final rightWrist = pose.landmarks[PoseLandmarkType.rightWrist];
    
    // ✅ Validation stricte des landmarks (avec confiance ET cohérence anatomique)
    bool leftValid = _areAllLandmarksValid(leftShoulder, leftElbow, leftWrist);
    bool rightValid = _areAllLandmarksValid(rightShoulder, rightElbow, rightWrist);
    
    if (!leftValid && !rightValid) return;
    
    // Calcul des angles
    double? leftAngle;
    double? rightAngle;
    
    if (leftValid) {
      leftAngle = _calculateAngle(leftShoulder!, leftElbow!, leftWrist!);
    }
    if (rightValid) {
      rightAngle = _calculateAngle(rightShoulder!, rightElbow!, rightWrist!);
    }
    
    // ✅ Détection automatique du bras actif avec info de confiance
    ActiveArm detectedArm = _detectActiveArm(
      leftAngle, 
      rightAngle,
      leftValid,  // Passe l'info de validité/confiance
      rightValid,
    );
    
    // Si on détecte un nouveau bras actif différent, reset
    if (detectedArm != _activeArm && detectedArm != ActiveArm.none) {
      if (_currentState == CurlState.repos) {
        _activeArm = detectedArm;
        _framesWithoutMovement = 0;
      }
    }
    
    // Si aucun bras actif, ne rien faire
    if (_activeArm == ActiveArm.none) {
      _activeArm = detectedArm;
      return;
    }
    
    // Sélectionner les landmarks du bras actif
    PoseLandmark? shoulder;
    PoseLandmark? elbow;
    PoseLandmark? wrist;
    double? angle;
    
    if (_activeArm == ActiveArm.left && leftValid) {
      shoulder = leftShoulder;
      elbow = leftElbow;
      wrist = leftWrist;
      angle = leftAngle;
    } else if (_activeArm == ActiveArm.right && rightValid) {
      shoulder = rightShoulder;
      elbow = rightElbow;
      wrist = rightWrist;
      angle = rightAngle;
    } else {
      // ✅ NOUVEAU : Si le bras actif n'est plus valide, reset
      if (_currentState == CurlState.repos) {
        _activeArm = ActiveArm.none;
      }
      return; // Bras actif non disponible
    }
    
    if (angle == null) return;
    
    // Lissage
    double smoothedAngle = _addAndSmooth(_recentAngles, angle);
    
    // Suivre les extremums du mouvement
    _minAngleThisRep = min(_minAngleThisRep, smoothedAngle);
    _maxAngleThisRep = max(_maxAngleThisRep, smoothedAngle);
    
    // Détection de triche
    _updateCheatDetection(shoulder!.y, elbow!.x);
    
    // Machine à états
    _updateState(smoothedAngle);
  }

  // ==================== FILTRAGE DES LANDMARKS POUR L'AFFICHAGE ====================
  
  /// Retourne la liste des types de landmarks à afficher pour cet exercice
  /// Utilisé pour filtrer l'affichage dans le painter
  Set<PoseLandmarkType> getVisibleLandmarkTypes() {
    // Si aucun bras actif, afficher tous les landmarks (mode découverte)
    if (_activeArm == ActiveArm.none) {
      return _getAllLandmarkTypes();
    }
    
    // Landmarks communs (toujours visibles)
    Set<PoseLandmarkType> visible = {
      PoseLandmarkType.nose,
      PoseLandmarkType.leftEye,
      PoseLandmarkType.rightEye,
      PoseLandmarkType.leftEar,
      PoseLandmarkType.rightEar,
      // Les deux épaules pour la référence de posture
      PoseLandmarkType.leftShoulder,
      PoseLandmarkType.rightShoulder,
    };
    
    // Ajouter les landmarks du bras actif
    if (_activeArm == ActiveArm.left) {
      visible.addAll({
        PoseLandmarkType.leftElbow,
        PoseLandmarkType.leftWrist,
        PoseLandmarkType.leftPinky,
        PoseLandmarkType.leftIndex,
        PoseLandmarkType.leftThumb,
      });
    } else if (_activeArm == ActiveArm.right) {
      visible.addAll({
        PoseLandmarkType.rightElbow,
        PoseLandmarkType.rightWrist,
        PoseLandmarkType.rightPinky,
        PoseLandmarkType.rightIndex,
        PoseLandmarkType.rightThumb,
      });
    } else if (_activeArm == ActiveArm.both) {
      // Les deux bras
      visible.addAll({
        PoseLandmarkType.leftElbow,
        PoseLandmarkType.leftWrist,
        PoseLandmarkType.leftPinky,
        PoseLandmarkType.leftIndex,
        PoseLandmarkType.leftThumb,
        PoseLandmarkType.rightElbow,
        PoseLandmarkType.rightWrist,
        PoseLandmarkType.rightPinky,
        PoseLandmarkType.rightIndex,
        PoseLandmarkType.rightThumb,
      });
    }
    
    return visible;
  }
  
  /// Retourne tous les types de landmarks disponibles
  Set<PoseLandmarkType> _getAllLandmarkTypes() {
    return {
      PoseLandmarkType.nose,
      PoseLandmarkType.leftEyeInner,
      PoseLandmarkType.leftEye,
      PoseLandmarkType.leftEyeOuter,
      PoseLandmarkType.rightEyeInner,
      PoseLandmarkType.rightEye,
      PoseLandmarkType.rightEyeOuter,
      PoseLandmarkType.leftEar,
      PoseLandmarkType.rightEar,
      PoseLandmarkType.leftMouth,
      PoseLandmarkType.rightMouth,
      PoseLandmarkType.leftShoulder,
      PoseLandmarkType.rightShoulder,
      PoseLandmarkType.leftElbow,
      PoseLandmarkType.rightElbow,
      PoseLandmarkType.leftWrist,
      PoseLandmarkType.rightWrist,
      PoseLandmarkType.leftPinky,
      PoseLandmarkType.rightPinky,
      PoseLandmarkType.leftIndex,
      PoseLandmarkType.rightIndex,
      PoseLandmarkType.leftThumb,
      PoseLandmarkType.rightThumb,
      PoseLandmarkType.leftHip,
      PoseLandmarkType.rightHip,
      PoseLandmarkType.leftKnee,
      PoseLandmarkType.rightKnee,
      PoseLandmarkType.leftAnkle,
      PoseLandmarkType.rightAnkle,
      PoseLandmarkType.leftHeel,
      PoseLandmarkType.rightHeel,
      PoseLandmarkType.leftFootIndex,
      PoseLandmarkType.rightFootIndex,
    };
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
    _recentLeftAngles.clear();
    _recentRightAngles.clear();
    _activeArm = ActiveArm.none;
    _framesWithoutMovement = 0;
  }

  void resetCalibration() {
    _isCalibrated = false;
    _calibrationMinAngles.clear();
    _calibrationMaxAngles.clear();
    _minAngle = 40;
    _maxAngle = 160;
  }
}

// ==================== CLASSE HELPER ====================
class _Vector2D {
  final double dx;
  final double dy;
  _Vector2D(this.dx, this.dy);
}
