import 'package:flutter/material.dart';

/// OpenGlucose visual language.
///
/// The brand mark is a black disc with a white rounded-square cutout. The app
/// follows it literally: one ink, one paper, and a short grey ramp between
/// them. Meaning is carried by contrast, weight, and shape instead of hue, so
/// every state reads the same on a greyscale screen, in bright sun, and for
/// people with colour-vision differences.
abstract final class OgColors {
  /// Page and card-on-ink foreground.
  static const Color paper = Color(0xFFFFFFFF);

  /// Primary text, primary surfaces, and the chart line.
  static const Color ink = Color(0xFF0A0A0A);

  /// Secondary text on paper.
  static const Color graphite = Color(0xFF4A4A4A);

  /// Muted labels, captions, and axis text on paper.
  static const Color ash = Color(0xFF8C8C8C);

  /// Hairlines, inactive tracks, grid lines.
  static const Color mist = Color(0xFFE4E4E4);

  /// Soft fills: cards, chips, inset panels, fields.
  static const Color fog = Color(0xFFF4F4F4);

  /// Secondary text on ink.
  static const Color inkMuted = Color(0xFFB4B4B4);

  /// Raised fill on ink surfaces.
  static const Color inkRaised = Color(0xFF1E1E1E);

  /// Outline on ink surfaces.
  static const Color inkOutline = Color(0xFF3C3C3C);
}

abstract final class OgRadius {
  static const double hero = 28;
  static const double card = 24;
  static const double inset = 16;
  static const double field = 14;
}

const List<FontFeature> _tabularFigures = <FontFeature>[
  FontFeature.tabularFigures(),
];

/// Builds the monochrome Material theme used by every OpenGlucose surface.
ThemeData buildOpenGlucoseTheme() {
  const scheme = ColorScheme(
    brightness: Brightness.light,
    primary: OgColors.ink,
    onPrimary: OgColors.paper,
    primaryContainer: OgColors.ink,
    onPrimaryContainer: OgColors.paper,
    secondary: OgColors.graphite,
    onSecondary: OgColors.paper,
    secondaryContainer: OgColors.mist,
    onSecondaryContainer: OgColors.ink,
    tertiary: OgColors.ash,
    onTertiary: OgColors.paper,
    tertiaryContainer: OgColors.fog,
    onTertiaryContainer: OgColors.ink,
    error: OgColors.ink,
    onError: OgColors.paper,
    errorContainer: OgColors.fog,
    onErrorContainer: OgColors.ink,
    surface: OgColors.paper,
    onSurface: OgColors.ink,
    surfaceDim: OgColors.fog,
    surfaceBright: OgColors.paper,
    surfaceContainerLowest: OgColors.paper,
    surfaceContainerLow: OgColors.fog,
    surfaceContainer: OgColors.fog,
    surfaceContainerHigh: OgColors.fog,
    surfaceContainerHighest: OgColors.fog,
    onSurfaceVariant: OgColors.ash,
    outline: Color(0xFFD2D2D2),
    outlineVariant: OgColors.mist,
    shadow: OgColors.ink,
    scrim: OgColors.ink,
    inverseSurface: OgColors.ink,
    onInverseSurface: OgColors.paper,
    inversePrimary: OgColors.paper,
    surfaceTint: Colors.transparent,
  );

  final base = ThemeData(useMaterial3: true, colorScheme: scheme);
  final text = base.textTheme;
  final textTheme = text
      .copyWith(
        displayLarge: text.displayLarge?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: -3,
          height: 1,
          fontFeatures: _tabularFigures,
        ),
        displayMedium: text.displayMedium?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: -2.4,
          height: 1,
          fontFeatures: _tabularFigures,
        ),
        displaySmall: text.displaySmall?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: -1.6,
          height: 1.05,
          fontFeatures: _tabularFigures,
        ),
        headlineMedium: text.headlineMedium?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: -0.9,
          height: 1.1,
        ),
        headlineSmall: text.headlineSmall?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: -0.6,
          height: 1.15,
        ),
        titleLarge: text.titleLarge?.copyWith(
          fontWeight: FontWeight.w600,
          letterSpacing: -0.4,
        ),
        titleMedium: text.titleMedium?.copyWith(
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
        ),
        titleSmall: text.titleSmall?.copyWith(
          fontWeight: FontWeight.w600,
          letterSpacing: 0,
        ),
        bodyLarge: text.bodyLarge?.copyWith(height: 1.4, letterSpacing: 0),
        bodyMedium: text.bodyMedium?.copyWith(height: 1.4, letterSpacing: 0),
        bodySmall: text.bodySmall?.copyWith(height: 1.35, letterSpacing: 0),
        labelLarge: text.labelLarge?.copyWith(
          fontWeight: FontWeight.w600,
          letterSpacing: 0.1,
        ),
        labelMedium: text.labelMedium?.copyWith(
          fontWeight: FontWeight.w600,
          letterSpacing: 0.6,
        ),
        labelSmall: text.labelSmall?.copyWith(letterSpacing: 0.4),
      )
      .apply(bodyColor: OgColors.ink, displayColor: OgColors.ink);

  final pill = RoundedRectangleBorder(borderRadius: BorderRadius.circular(999));
  const buttonPadding = EdgeInsets.symmetric(horizontal: 20, vertical: 14);
  final buttonText = textTheme.labelLarge?.copyWith(fontSize: 15);

  return base.copyWith(
    textTheme: textTheme,
    scaffoldBackgroundColor: OgColors.paper,
    canvasColor: OgColors.paper,
    splashFactory: InkSparkle.splashFactory,
    splashColor: OgColors.ink.withValues(alpha: 0.06),
    highlightColor: OgColors.ink.withValues(alpha: 0.04),
    hoverColor: OgColors.ink.withValues(alpha: 0.03),
    focusColor: OgColors.ink.withValues(alpha: 0.08),
    dividerColor: OgColors.mist,
    visualDensity: VisualDensity.standard,
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: <TargetPlatform, PageTransitionsBuilder>{
        TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.fuchsia: FadeForwardsPageTransitionsBuilder(),
      },
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: OgColors.paper,
      foregroundColor: OgColors.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
      iconTheme: const IconThemeData(color: OgColors.ink),
    ),
    cardTheme: CardThemeData(
      color: OgColors.fog,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(OgRadius.card),
      ),
    ),
    dividerTheme: const DividerThemeData(
      color: OgColors.mist,
      thickness: 1,
      space: 1,
    ),
    iconTheme: const IconThemeData(color: OgColors.ink),
    listTileTheme: ListTileThemeData(
      iconColor: OgColors.ink,
      textColor: OgColors.ink,
      titleTextStyle: textTheme.bodyLarge?.copyWith(
        fontWeight: FontWeight.w600,
      ),
      subtitleTextStyle: textTheme.bodyMedium?.copyWith(color: OgColors.ash),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStatePropertyAll<OutlinedBorder>(pill),
        padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
          buttonPadding,
        ),
        textStyle: WidgetStatePropertyAll<TextStyle?>(buttonText),
        elevation: const WidgetStatePropertyAll<double>(0),
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return OgColors.mist;
          }
          return OgColors.ink;
        }),
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return OgColors.ash;
          }
          return OgColors.paper;
        }),
        iconColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return OgColors.ash;
          }
          return OgColors.paper;
        }),
        overlayColor: WidgetStatePropertyAll<Color>(
          OgColors.paper.withValues(alpha: 0.10),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStatePropertyAll<OutlinedBorder>(pill),
        padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
          buttonPadding,
        ),
        textStyle: WidgetStatePropertyAll<TextStyle?>(buttonText),
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return OgColors.ash;
          }
          return OgColors.ink;
        }),
        iconColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return OgColors.ash;
          }
          return OgColors.ink;
        }),
        side: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return const BorderSide(color: OgColors.mist);
          }
          return const BorderSide(color: Color(0xFFCFCFCF));
        }),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStatePropertyAll<OutlinedBorder>(pill),
        textStyle: WidgetStatePropertyAll<TextStyle?>(buttonText),
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return OgColors.ash;
          }
          return OgColors.ink;
        }),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return OgColors.ash;
          }
          return OgColors.ink;
        }),
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStatePropertyAll<OutlinedBorder>(pill),
        side: const WidgetStatePropertyAll<BorderSide>(
          BorderSide(color: OgColors.mist),
        ),
        textStyle: WidgetStatePropertyAll<TextStyle?>(textTheme.labelLarge),
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return OgColors.ink;
          }
          return OgColors.paper;
        }),
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return OgColors.paper;
          }
          if (states.contains(WidgetState.disabled)) {
            return OgColors.ash;
          }
          return OgColors.ink;
        }),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: OgColors.fog,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      labelStyle: const TextStyle(color: OgColors.ash),
      floatingLabelStyle: const TextStyle(color: OgColors.ink),
      hintStyle: const TextStyle(color: OgColors.ash),
      helperStyle: const TextStyle(color: OgColors.ash),
      errorStyle: const TextStyle(
        color: OgColors.ink,
        fontWeight: FontWeight.w600,
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(OgRadius.field),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(OgRadius.field),
        borderSide: BorderSide.none,
      ),
      disabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(OgRadius.field),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(OgRadius.field),
        borderSide: const BorderSide(color: OgColors.ink, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(OgRadius.field),
        borderSide: const BorderSide(color: OgColors.ink),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(OgRadius.field),
        borderSide: const BorderSide(color: OgColors.ink, width: 1.5),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return OgColors.mist;
        }
        return OgColors.paper;
      }),
      trackColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return OgColors.fog;
        }
        if (states.contains(WidgetState.selected)) {
          return OgColors.ink;
        }
        return const Color(0xFFCFCFCF);
      }),
      trackOutlineColor: const WidgetStatePropertyAll<Color>(
        Colors.transparent,
      ),
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return OgColors.mist;
        }
        return OgColors.ink;
      }),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return OgColors.ink;
        }
        return Colors.transparent;
      }),
      checkColor: const WidgetStatePropertyAll<Color>(OgColors.paper),
      side: const BorderSide(color: OgColors.ink, width: 1.5),
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: OgColors.ink,
      inactiveTrackColor: OgColors.mist,
      thumbColor: OgColors.ink,
      overlayColor: const Color(0x140A0A0A),
      valueIndicatorColor: OgColors.ink,
      valueIndicatorTextStyle: const TextStyle(color: OgColors.paper),
      rangeThumbShape: const RoundRangeSliderThumbShape(enabledThumbRadius: 11),
      tickMarkShape: SliderTickMarkShape.noTickMark,
      rangeTickMarkShape: RoundRangeSliderTickMarkShape(tickMarkRadius: 0),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: OgColors.ink,
      linearTrackColor: OgColors.mist,
      circularTrackColor: OgColors.mist,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: OgColors.ink,
      contentTextStyle: textTheme.bodyMedium?.copyWith(color: OgColors.paper),
      actionTextColor: OgColors.paper,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(OgRadius.inset),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: OgColors.paper,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(OgRadius.card),
      ),
      titleTextStyle: textTheme.titleLarge,
      contentTextStyle: textTheme.bodyMedium?.copyWith(
        color: OgColors.graphite,
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: OgColors.paper,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
    ),
    expansionTileTheme: const ExpansionTileThemeData(
      iconColor: OgColors.ink,
      collapsedIconColor: OgColors.ink,
      textColor: OgColors.ink,
      collapsedTextColor: OgColors.ink,
      shape: Border(),
      collapsedShape: Border(),
    ),
    dropdownMenuTheme: DropdownMenuThemeData(
      textStyle: textTheme.bodyLarge,
      menuStyle: MenuStyle(
        backgroundColor: const WidgetStatePropertyAll<Color>(OgColors.paper),
        surfaceTintColor: const WidgetStatePropertyAll<Color>(
          Colors.transparent,
        ),
        shape: WidgetStatePropertyAll<OutlinedBorder>(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(OgRadius.inset),
          ),
        ),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: OgColors.paper,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(OgRadius.inset),
      ),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: OgColors.ink,
        borderRadius: BorderRadius.circular(8),
      ),
      textStyle: const TextStyle(color: OgColors.paper),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: OgColors.fog,
      selectedColor: OgColors.ink,
      side: BorderSide.none,
      shape: pill,
      labelStyle: textTheme.labelLarge,
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: OgColors.ink,
      selectionColor: OgColors.ink.withValues(alpha: 0.16),
      selectionHandleColor: OgColors.ink,
    ),
  );
}

/// The brand mark's cutout: a small rounded square.
///
/// Filled means "on" (live, present, improved). Hollow means "attention"
/// (waiting, missing, worse). It is the one status glyph in the app.
class OgMark extends StatelessWidget {
  const OgMark({
    super.key,
    this.size = 10,
    this.filled = true,
    this.color = OgColors.ink,
  });

  final double size;
  final bool filled;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: filled ? color : Colors.transparent,
          border: filled ? null : Border.all(color: color, width: 1.5),
          borderRadius: BorderRadius.circular(size * 0.3),
        ),
      ),
    );
  }
}

/// The brand mark drawn in code: a disc with a rounded-square cutout at its
/// right. Drawing it keeps edges crisp at any size and lets it invert on ink.
class OgLogoMark extends StatelessWidget {
  const OgLogoMark({
    super.key,
    this.size = 28,
    this.color = OgColors.ink,
    this.cutout = OgColors.paper,
  });

  final double size;
  final Color color;
  final Color cutout;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(painter: _OgLogoMarkPainter(color, cutout)),
    );
  }
}

class _OgLogoMarkPainter extends CustomPainter {
  const _OgLogoMarkPainter(this.color, this.cutout);

  final Color color;
  final Color cutout;

  @override
  void paint(Canvas canvas, Size size) {
    final d = size.shortestSide;
    final center = Offset(size.width / 2, size.height / 2);
    canvas.drawCircle(center, d / 2, Paint()..color = color);
    final side = d * 0.222;
    final square = Rect.fromCenter(
      center: center.translate(d * 0.246, 0),
      width: side,
      height: side,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(square, Radius.circular(d * 0.035)),
      Paint()..color = cutout,
    );
  }

  @override
  bool shouldRepaint(_OgLogoMarkPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.cutout != cutout;
}

/// Tone of a status pill. Solid is the resting "good" state; soft is a
/// transitional state; outline asks for attention.
enum OgTone { solid, soft, outline }

/// Compact status pill with the brand mark as its glyph.
class OgPill extends StatelessWidget {
  const OgPill({
    super.key,
    required this.label,
    this.tone = OgTone.solid,
    this.onInk = false,
    this.dense = false,
  });

  final String label;
  final OgTone tone;

  /// Set when the pill sits on an ink surface so contrast flips.
  final bool onInk;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final Color background;
    final Color foreground;
    final Border? border;
    switch (tone) {
      case OgTone.solid:
        background = onInk ? OgColors.paper : OgColors.ink;
        foreground = onInk ? OgColors.ink : OgColors.paper;
        border = null;
      case OgTone.soft:
        background = onInk ? OgColors.inkRaised : OgColors.mist;
        foreground = onInk ? OgColors.paper : OgColors.ink;
        border = null;
      case OgTone.outline:
        background = Colors.transparent;
        foreground = onInk ? OgColors.paper : OgColors.ink;
        border = Border.all(
          color: onInk ? OgColors.inkOutline : const Color(0xFFCFCFCF),
        );
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        border: border,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: dense ? 10 : 12,
          vertical: dense ? 5 : 7,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            OgMark(
              size: dense ? 7 : 8,
              filled: tone != OgTone.outline,
              color: foreground,
            ),
            SizedBox(width: dense ? 6 : 8),
            Text(
              label,
              style: TextStyle(
                color: foreground,
                fontWeight: FontWeight.w600,
                fontSize: dense ? 12 : 13,
                height: 1.2,
                letterSpacing: 0.1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Full-width ink banner for a claim the reader must not miss, such as
/// "demo data" or "sample data". Loud through contrast, not colour.
class OgNoticeBar extends StatelessWidget {
  const OgNoticeBar({super.key, required this.label, this.icon});

  final String label;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: OgColors.ink,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            if (icon != null) ...<Widget>[
              Icon(icon, size: 16, color: OgColors.paper),
              const SizedBox(width: 8),
            ] else ...<Widget>[
              const OgMark(size: 8, filled: false, color: OgColors.paper),
              const SizedBox(width: 10),
            ],
            Flexible(
              child: Text(
                label,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: OgColors.paper,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                  letterSpacing: 0.2,
                  height: 1.3,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
