package life.devops.passwordmanager.ui

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class WindowLayoutPolicyTest {
    @Test
    fun compactWidthUsesSinglePaneWithoutSeparatingFold() {
        assertFalse(WindowLayoutPolicy.shouldUseTwoPaneLayout(399, hasSeparatingFold = false))
    }

    @Test
    fun expandedWidthUsesTwoPaneLayout() {
        assertTrue(WindowLayoutPolicy.shouldUseTwoPaneLayout(700, hasSeparatingFold = false))
    }

    @Test
    fun verticalSeparatingFoldUsesTwoPaneLayoutEvenBelowWidthThreshold() {
        assertTrue(WindowLayoutPolicy.shouldUseTwoPaneLayout(500, hasSeparatingFold = true))
    }

    @Test
    fun horizontalSeparatingFoldUsesTwoPaneLayoutEvenBelowWidthThreshold() {
        assertTrue(WindowLayoutPolicy.shouldUseTwoPaneLayout(500, hasSeparatingFold = true))
    }
}
