package life.devops.passwordmanager.ui

object WindowLayoutPolicy {
    private const val ExpandedWidthDp = 600

    data class Region(val left: Int, val top: Int, val right: Int, val bottom: Int) {
        val width: Int get() = (right - left).coerceAtLeast(0)
        val height: Int get() = (bottom - top).coerceAtLeast(0)
    }

    data class Fold(val bounds: Region, val horizontal: Boolean)

    fun shouldUseTwoPaneLayout(widthDp: Int, hasSeparatingFold: Boolean): Boolean =
        widthDp >= ExpandedWidthDp || hasSeparatingFold

    fun paneRegions(available: Region, fold: Fold?, twoPane: Boolean, gap: Int): List<Region> {
        val separated = separatedRegions(available, fold)
        if (separated.size == 2) {
            val gutter = gap.coerceAtLeast(0) / 2
            val first = separated[0]
            val second = separated[1]
            return if (fold?.horizontal == true) {
                listOf(
                    first.copy(bottom = first.bottom - gutter.coerceAtMost(first.height / 4)),
                    second.copy(top = second.top + gutter.coerceAtMost(second.height / 4)),
                )
            } else {
                listOf(
                    first.copy(right = first.right - gutter.coerceAtMost(first.width / 4)),
                    second.copy(left = second.left + gutter.coerceAtMost(second.width / 4)),
                )
            }
        }
        if (!twoPane) return listOf(available)
        val gutter = gap.coerceIn(0, available.width / 4)
        val split = available.left + ((available.width - gutter) * 0.42f).toInt()
        return listOf(
            available.copy(right = split),
            available.copy(left = split + gutter),
        )
    }

    fun dialogRegion(
        available: Region,
        fold: Fold?,
        margin: Int,
        maxWidth: Int,
        maxHeight: Int,
    ): Region {
        val pane = separatedRegions(available, fold)
            .maxBy { it.width.toLong() * it.height }
        val horizontalMargin = margin.coerceIn(0, pane.width / 4)
        val verticalMargin = margin.coerceIn(0, pane.height / 4)
        val width = (pane.width - 2 * horizontalMargin).coerceAtMost(maxWidth.coerceAtLeast(0))
        val height = (pane.height - 2 * verticalMargin).coerceAtMost(maxHeight.coerceAtLeast(0))
        val left = pane.left + (pane.width - width) / 2
        val top = pane.top + (pane.height - height) / 2
        return Region(left, top, left + width, top + height)
    }

    fun useEditorColumns(availableWidthDp: Int, fontScale: Float): Boolean =
        availableWidthDp >= 600 * fontScale.coerceAtLeast(1f)

    private fun separatedRegions(available: Region, fold: Fold?): List<Region> {
        if (fold == null) return listOf(available)
        val bounds = fold.bounds
        // Fold coordinates are relative to the window, just like the available region.
        val regions = if (fold.horizontal) {
            if (bounds.top <= available.top || bounds.bottom >= available.bottom) return listOf(available)
            listOf(available.copy(bottom = bounds.top), available.copy(top = bounds.bottom))
        } else {
            if (bounds.left <= available.left || bounds.right >= available.right) return listOf(available)
            listOf(available.copy(right = bounds.left), available.copy(left = bounds.right))
        }
        return regions
    }
}
