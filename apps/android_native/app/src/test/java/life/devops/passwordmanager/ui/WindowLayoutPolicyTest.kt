package life.devops.passwordmanager.ui

import kotlin.test.Test
import life.devops.passwordmanager.ui.WindowLayoutPolicy.Region
import life.devops.passwordmanager.ui.WindowLayoutPolicy.Fold
import kotlin.test.assertEquals
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
    fun unfoldedInnerDisplayUsesTwoPanesAtMediumWidthBoundary() {
        assertFalse(WindowLayoutPolicy.shouldUseTwoPaneLayout(599, hasSeparatingFold = false))
        assertTrue(WindowLayoutPolicy.shouldUseTwoPaneLayout(600, hasSeparatingFold = false))
        assertTrue(WindowLayoutPolicy.shouldUseTwoPaneLayout(673, hasSeparatingFold = false))
    }

    @Test
    fun verticalSeparatingFoldUsesTwoPaneLayoutEvenBelowWidthThreshold() {
        assertTrue(WindowLayoutPolicy.shouldUseTwoPaneLayout(500, hasSeparatingFold = true))
    }

    @Test
    fun horizontalSeparatingFoldUsesTwoPaneLayoutEvenBelowWidthThreshold() {
        assertTrue(WindowLayoutPolicy.shouldUseTwoPaneLayout(500, hasSeparatingFold = true))
    }

    @Test
    fun offCenterVerticalHingeUsesItsActualCoordinates() {
        val regions = WindowLayoutPolicy.paneRegions(
            Region(16, 40, 984, 800), Fold(Region(420, 0, 444, 840), false), true, 16,
        )
        assertEquals(listOf(Region(16, 40, 412, 800), Region(452, 40, 984, 800)), regions)
    }

    @Test
    fun tabletopRespectsTopInsetAndHingeThickness() {
        val regions = WindowLayoutPolicy.paneRegions(
            Region(16, 40, 984, 1180), Fold(Region(0, 500, 1000, 524), true), true, 16,
        )
        assertEquals(listOf(Region(16, 40, 984, 492), Region(16, 532, 984, 1180)), regions)
    }

    @Test
    fun zeroWidthCreaseStillSeparatesThePanes() {
        val regions = WindowLayoutPolicy.paneRegions(
            Region(0, 0, 1000, 800), Fold(Region(500, 0, 500, 800), false), true, 16,
        )
        assertEquals(492, regions[0].right)
        assertEquals(508, regions[1].left)
    }

    @Test
    fun compactWindowUsesItsWholeAvailableRegion() {
        val available = Region(8, 40, 352, 760)
        assertEquals(listOf(available), WindowLayoutPolicy.paneRegions(available, null, false, 16))
    }

    @Test
    fun expandedWindowSeparatesListAndDetailsWithGutter() {
        val regions = WindowLayoutPolicy.paneRegions(Region(16, 40, 984, 800), null, true, 16)
        assertEquals(16, regions[1].left - regions[0].right)
        assertTrue(regions[1].width > regions[0].width)
    }

    @Test
    fun dialogFitsInsideLargestVerticalPane() {
        val bounds = WindowLayoutPolicy.dialogRegion(
            Region(0, 40, 1000, 900), Fold(Region(420, 0, 444, 940), false), 16, 720, 840,
        )
        assertTrue(bounds.left >= 460)
        assertTrue(bounds.right <= 984)
        assertTrue(bounds.top >= 56 && bounds.bottom <= 884)
    }

    @Test
    fun dialogFitsInsideTabletopPaneWithoutCoveringHinge() {
        val bounds = WindowLayoutPolicy.dialogRegion(
            Region(0, 40, 1000, 1100), Fold(Region(0, 500, 1000, 524), true), 16, 720, 840,
        )
        assertTrue(bounds.top >= 540)
        assertTrue(bounds.bottom <= 1084)
    }

    @Test
    fun tinyWindowNeverExpandsDialogBeyondAvailableSpace() {
        val available = Region(0, 0, 240, 200)
        val bounds = WindowLayoutPolicy.dialogRegion(available, null, 16, 720, 840)
        assertTrue(bounds.left >= 0 && bounds.right <= 240)
        assertTrue(bounds.top >= 0 && bounds.bottom <= 200)
    }

    @Test
    fun dialogAvoidsKeyboardAreaAndCapsTabletWidth() {
        val bounds = WindowLayoutPolicy.dialogRegion(Region(0, 40, 1600, 600), null, 16, 720, 840)
        assertEquals(720, bounds.width)
        assertTrue(bounds.bottom <= 584)
    }

    @Test
    fun foldOutsideAvailableWindowDoesNotProduceNegativePanes() {
        val available = Region(0, 600, 1000, 900)
        assertEquals(listOf(available), WindowLayoutPolicy.paneRegions(
            available, Fold(Region(0, 500, 1000, 524), true), false, 16,
        ))
    }

    @Test
    fun editorColumnsFollowActualPaneWidthAndFontScale() {
        assertFalse(WindowLayoutPolicy.useEditorColumns(560, 1f))
        assertTrue(WindowLayoutPolicy.useEditorColumns(640, 1f))
        assertFalse(WindowLayoutPolicy.useEditorColumns(720, 1.5f))
    }
}
