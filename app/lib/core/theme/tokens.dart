// Jetons du design system « Clarté européenne ». Source unique des couleurs,
// rayons et espacements : aucun écran ne code une couleur en dur.
import 'package:flutter/material.dart';

abstract final class LumoColors {
  static const action = Color(0xFF2B3CF0);      // bleu : uniquement pour agir
  static const actionSoft = Color(0xFFEBEDFF);  // sélection, fonds d'accent
  static const lime = Color(0xFFD4F34A);        // avantage / nouveauté (jamais un bouton)
  static const ink = Color(0xFF0E1116);         // texte principal
  static const slate = Color(0xFF4A5260);       // texte secondaire (7,6:1 sur blanc)
  static const mist = Color(0xFFF4F5F7);        // fond d'écran
  static const line = Color(0xFFE3E5EA);        // bordures
  static const surface = Color(0xFFFFFFFF);
  static const success = Color(0xFF0B6E4C);
  static const successSoft = Color(0xFFE3F5EC);
  static const warning = Color(0xFF9A4A06);
  static const danger = Color(0xFFB4213A);

  // Fonds des visuels produits en attendant les vraies photos.
  static const photoTones = [
    Color(0xFFDCE3D6), Color(0xFFE3E1F0), Color(0xFFF0E4D8), Color(0xFFD8E6EC),
  ];
}

abstract final class LumoRadius {
  static const card = 12.0;
  static const field = 14.0;
  static const panel = 20.0;
  static const pill = 999.0;
}

abstract final class LumoSpace {
  static const xs = 4.0, s = 8.0, m = 12.0, l = 16.0, xl = 24.0, xxl = 32.0;
  static const minTouch = 44.0; // cible tactile minimale
}

/// Largeur à partir de laquelle on passe en mise en page bureau (Windows).
const double kDesktopBreakpoint = 1024;
