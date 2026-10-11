package life.devops.passwordmanager.ui

object WindowLayoutPolicy {
    private const val ExpandedWidthDp = 700

    fun shouldUseTwoPaneLayout(
        widthDp: Int,
        hasSeparatingFold: Boolean,
    ): Boolean = widthDp >= ExpandedWidthDp || hasSeparatingFold
}
