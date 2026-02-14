import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

enum WindowSizeClass { compact, medium, expanded }

WindowSizeClass windowSizeClassFor(double width) {
  if (width < 600) {
    return WindowSizeClass.compact;
  }
  if (width < 840) {
    return WindowSizeClass.medium;
  }
  return WindowSizeClass.expanded;
}

class FoldablePaneSplit {
  const FoldablePaneSplit({
    required this.axis,
    required this.startExtent,
    required this.gapExtent,
    required this.endExtent,
  });

  final Axis axis;
  final double startExtent;
  final double gapExtent;
  final double endExtent;
}

FoldablePaneSplit? foldablePaneSplitFor({
  required BuildContext context,
  required Size availableSize,
  double minPaneExtent = 320,
}) {
  final view = View.of(context);
  final data = MediaQueryData.fromView(view);
  final feature = _findFoldableFeature(data.displayFeatures);
  if (feature == null) {
    return null;
  }
  final adjustedBounds = _adjustBounds(
    feature.bounds,
    data.padding,
    availableSize,
  );
  if (adjustedBounds == null) {
    return null;
  }
  final axis = _axisFromBounds(adjustedBounds);
  final gap = axis == Axis.vertical
      ? adjustedBounds.width
      : adjustedBounds.height;
  final split = axis == Axis.vertical
      ? adjustedBounds.center.dx
      : adjustedBounds.center.dy;
  final total = axis == Axis.vertical
      ? availableSize.width
      : availableSize.height;
  final start = split - gap / 2;
  final end = total - split - gap / 2;
  if (start < minPaneExtent || end < minPaneExtent) {
    return null;
  }
  return FoldablePaneSplit(
    axis: axis,
    startExtent: start,
    gapExtent: gap,
    endExtent: end,
  );
}

ui.DisplayFeature? foldableDisplayFeatureFor(BuildContext context) {
  final view = View.of(context);
  final data = MediaQueryData.fromView(view);
  return _findFoldableFeature(data.displayFeatures);
}

bool hasFoldableDisplayFeature(BuildContext context) {
  return foldableDisplayFeatureFor(context) != null;
}

bool isFoldedPosture(BuildContext context) {
  final feature = foldableDisplayFeatureFor(context);
  if (feature == null) {
    return false;
  }
  return feature.state == ui.DisplayFeatureState.postureHalfOpened;
}

ui.DisplayFeature? _findFoldableFeature(List<ui.DisplayFeature> features) {
  for (final feature in features) {
    if (feature.type == ui.DisplayFeatureType.hinge ||
        feature.type == ui.DisplayFeatureType.fold) {
      return feature;
    }
  }
  return null;
}

Rect? _adjustBounds(Rect bounds, EdgeInsets padding, Size availableSize) {
  final shifted = bounds.shift(Offset(-padding.left, -padding.top));
  final left = shifted.left.clamp(0, availableSize.width).toDouble();
  final right = shifted.right.clamp(0, availableSize.width).toDouble();
  final top = shifted.top.clamp(0, availableSize.height).toDouble();
  final bottom = shifted.bottom.clamp(0, availableSize.height).toDouble();
  if (left == right && top == bottom) {
    return null;
  }
  return Rect.fromLTRB(left, top, right, bottom);
}

Axis _axisFromBounds(Rect bounds) {
  return bounds.height >= bounds.width ? Axis.vertical : Axis.horizontal;
}
