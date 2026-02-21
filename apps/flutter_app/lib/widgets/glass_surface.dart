import 'dart:ui';

import 'package:flutter/material.dart';

class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.borderRadius = 16,
    this.padding,
    this.blur = 18,
    this.opacityLight = 0.75,
    this.opacityDark = 0.55,
    this.tint,
    this.showShadow = true,
    this.reduceEffects = false,
  });

  final Widget child;
  final double borderRadius;
  final EdgeInsets? padding;
  final double blur;
  final double opacityLight;
  final double opacityDark;
  final Color? tint;
  final bool showShadow;
  final bool reduceEffects;

  bool _useGlass(TargetPlatform platform) {
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.maybeOf(context);
    final platform = Theme.of(context).platform;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colorScheme = Theme.of(context).colorScheme;
    final reduceEffectsResolved =
        reduceEffects || (mediaQuery?.disableAnimations ?? false);
    final baseColor = tint ?? colorScheme.surface;
    final backgroundColor =
        baseColor.withOpacity(isDark ? opacityDark : opacityLight);
    final borderColor = colorScheme.outlineVariant.withOpacity(
      isDark ? 0.7 : 0.45,
    );
    final shadowBlur = reduceEffectsResolved ? 8.0 : 16.0;
    final shadowOpacity = reduceEffectsResolved
        ? (isDark ? 0.12 : 0.04)
        : (isDark ? 0.25 : 0.08);
    final shadowBlurGlass = reduceEffectsResolved ? 10.0 : 18.0;
    final shadowOpacityGlass = reduceEffectsResolved
        ? (isDark ? 0.18 : 0.06)
        : (isDark ? 0.35 : 0.12);

    final content = Padding(
      padding: padding ?? EdgeInsets.zero,
      child: child,
    );

    if (!_useGlass(platform) || reduceEffectsResolved) {
      return Container(
        decoration: BoxDecoration(
          color: backgroundColor,
          borderRadius: BorderRadius.circular(borderRadius),
          border: Border.all(color: borderColor),
          boxShadow: showShadow
              ? [
                  BoxShadow(
                    color: Colors.black.withOpacity(shadowOpacity),
                    blurRadius: shadowBlur,
                    offset: const Offset(0, 8),
                  ),
                ]
              : null,
        ),
        child: content,
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: Container(
          decoration: BoxDecoration(
            color: backgroundColor,
            borderRadius: BorderRadius.circular(borderRadius),
            border: Border.all(color: borderColor),
            boxShadow: showShadow
                ? [
                    BoxShadow(
                      color: Colors.black.withOpacity(shadowOpacityGlass),
                      blurRadius: shadowBlurGlass,
                      offset: const Offset(0, 8),
                    ),
                  ]
                : null,
          ),
          child: content,
        ),
      ),
    );
  }
}
