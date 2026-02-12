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
  });

  final Widget child;
  final double borderRadius;
  final EdgeInsets? padding;
  final double blur;
  final double opacityLight;
  final double opacityDark;
  final Color? tint;
  final bool showShadow;

  bool _useGlass(TargetPlatform platform) {
    return platform == TargetPlatform.iOS || platform == TargetPlatform.macOS;
  }

  @override
  Widget build(BuildContext context) {
    final platform = Theme.of(context).platform;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colorScheme = Theme.of(context).colorScheme;
    final baseColor = tint ?? colorScheme.surface;
    final backgroundColor =
        baseColor.withOpacity(isDark ? opacityDark : opacityLight);
    final borderColor = colorScheme.outlineVariant.withOpacity(
      isDark ? 0.7 : 0.45,
    );

    final content = Padding(
      padding: padding ?? EdgeInsets.zero,
      child: child,
    );

    if (!_useGlass(platform)) {
      return Container(
        decoration: BoxDecoration(
          color: backgroundColor,
          borderRadius: BorderRadius.circular(borderRadius),
          border: Border.all(color: borderColor),
          boxShadow: showShadow
              ? [
                  BoxShadow(
                    color: Colors.black.withOpacity(isDark ? 0.25 : 0.08),
                    blurRadius: 16,
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
                      color: Colors.black.withOpacity(isDark ? 0.35 : 0.12),
                      blurRadius: 18,
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
