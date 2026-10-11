package life.devops.passwordmanager

import android.graphics.Rect
import android.graphics.Bitmap
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsets
import android.widget.EditText
import android.widget.LinearLayout
import androidx.appcompat.app.AlertDialog
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.window.layout.FoldingFeature
import androidx.window.layout.WindowLayoutInfo
import androidx.window.testing.layout.FoldingFeature as testFoldingFeature
import androidx.window.testing.layout.WindowLayoutInfoPublisherRule
import com.google.android.material.button.MaterialButton
import com.google.android.material.chip.Chip
import com.google.android.material.textfield.TextInputLayout
import life.devops.passwordmanager.model.CustomField
import life.devops.passwordmanager.model.EntryDraft
import life.devops.passwordmanager.model.VaultEntry
import life.devops.passwordmanager.model.VaultEntryType
import life.devops.passwordmanager.store.VaultStore
import org.junit.Assert.*
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class ModernFoldableUiInstrumentedTest {
    @get:Rule val folding = WindowLayoutInfoPublisherRule()
    private val instrumentation = InstrumentationRegistry.getInstrumentation()

    @Before
    fun clearTestVault() {
        instrumentation.targetContext.filesDir.listFiles()?.forEach { it.deleteRecursively() }
        instrumentation.targetContext.getSharedPreferences("password_manager_android_preferences", 0)
            .edit().clear().commit()
    }

    @Test
    fun materialControlsKeepLabelsValidationAndSaveBehavior() {
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            scenario.onActivity { activity ->
                unlockFixture(activity)
                assertEquals("Name", activity.getString(R.string.custom_field_name))
                assertEquals("Value", activity.getString(R.string.custom_field_value))
                assertFalse(activity.getString(R.string.custom_field_name).contains("custom", ignoreCase = true))
                assertFalse(activity.getString(R.string.custom_field_value).contains("custom", ignoreCase = true))
                val views = descendants(activity.window.decorView)
                assertTrue(views.any { it is MaterialButton })
                assertTrue(views.any { it is Chip })
                openEditor(activity)
            }
            idle()
            capture("editor-material")
            scenario.onActivity { activity ->
                val dialog = editor(activity)
                val labels = descendants(dialog.window!!.decorView).filterIsInstance<TextInputLayout>()
                val name = labels.first { it.hint.toString() == activity.getString(R.string.label_field) }
                assertTrue(labels.all { !it.hint.isNullOrBlank() })
                dialog.getButton(AlertDialog.BUTTON_POSITIVE).performClick()
                assertEquals(activity.getString(R.string.label_required), name.error.toString())
                name.editText!!.setText("Saved from Material editor")
                dialog.getButton(AlertDialog.BUTTON_POSITIVE).performClick()
                assertFalse(dialog.isShowing)
                assertTrue(store(activity).listEntries().any { it.label == "Saved from Material editor" })
            }
        }
    }

    @Test
    fun savedCategoryNamesAreReadOnlyAndNewCategoryNamesLockAfterSave() {
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            scenario.onActivity { activity ->
                unlockFixture(activity)
                assertTrue(store(activity).addCategory("Name policy", null, listOf("Owner")))
                MainActivity::class.java.getDeclaredMethod(
                    "showCategoryTemplateEditor", String::class.java, kotlin.jvm.functions.Function0::class.java,
                ).apply { isAccessible = true }.invoke(activity, "Name policy", {})
            }
            idle()
            scenario.onActivity { activity ->
                val views = descendants(editor(activity).window!!.decorView)
                assertFalse(views.filterIsInstance<EditText>().single { it.text.toString() == "Owner" }.isEnabled)
                views.filterIsInstance<MaterialButton>()
                    .single { it.text.toString() == activity.getString(R.string.add_custom_field) }.performClick()
                val newName = descendants(editor(activity).window!!.decorView).filterIsInstance<EditText>()
                    .single { it.text.isNullOrEmpty() }
                assertTrue(newName.isEnabled)
                newName.setText("Region")
                editor(activity).getButton(AlertDialog.BUTTON_POSITIVE).performClick()
                assertTrue(store(activity).categoryTemplate("Name policy")!!.fields.any { it.name == "Region" })
            }
            idle()
            scenario.onActivity { activity ->
                MainActivity::class.java.getDeclaredMethod(
                    "showCategoryTemplateEditor", String::class.java, kotlin.jvm.functions.Function0::class.java,
                ).apply { isAccessible = true }.invoke(activity, "Name policy", {})
            }
            idle()
            scenario.onActivity { activity ->
                val names = descendants(editor(activity).window!!.decorView).filterIsInstance<EditText>()
                assertFalse(names.single { it.text.toString() == "Region" }.isEnabled)
            }
        }
    }

    @Test
    fun savedFieldNamesAreReadOnlyWhileNewFieldNamesRemainEditable() {
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            scenario.onActivity { activity ->
                unlockFixture(activity)
                val saved = store(activity).listEntries().first { it.label == "GitHub" }
                MainActivity::class.java.getDeclaredMethod(
                    "showEditor", VaultEntry::class.java, String::class.java, String::class.java, String::class.java,
                ).apply { isAccessible = true }.invoke(activity, saved, "", "", null)
            }
            idle()
            scenario.onActivity { activity ->
                val dialog = editor(activity)
                val inputs = descendants(dialog.window!!.decorView).filterIsInstance<EditText>()
                val name = inputs.single { it.text.toString() == "Username" }
                val value = inputs.single { it.text.toString() == "demo@example.com" }
                assertFalse(name.isEnabled)
                assertTrue(value.isEnabled)
                value.setText("updated@example.com")
                descendants(dialog.window!!.decorView).filterIsInstance<MaterialButton>()
                    .single { it.text.toString() == activity.getString(R.string.add_custom_field) }.performClick()
            }
            idle()
            scenario.onActivity { activity ->
                val dialog = editor(activity)
                val names = descendants(dialog.window!!.decorView).filterIsInstance<TextInputLayout>()
                    .filter { it.hint.toString() == activity.getString(R.string.custom_field_name) }
                val newName = names.mapNotNull { it.editText }.single { it.text.isNullOrEmpty() }
                assertTrue(newName.isEnabled)
                newName.setText("Region")
                dialog.getButton(AlertDialog.BUTTON_POSITIVE).performClick()
                val saved = store(activity).listEntries().first { it.label == "GitHub" }
                assertEquals("Username", saved.customFields.first { it.value == "updated@example.com" }.name)
                assertTrue(saved.customFields.any { it.name == "Region" })
                MainActivity::class.java.getDeclaredMethod(
                    "showEditor", VaultEntry::class.java, String::class.java, String::class.java, String::class.java,
                ).apply { isAccessible = true }.invoke(activity, saved, "", "", null)
            }
            idle()
            capture("saved-field-names-locked")
            scenario.onActivity { activity ->
                val names = descendants(editor(activity).window!!.decorView).filterIsInstance<TextInputLayout>()
                    .filter { it.hint.toString() == activity.getString(R.string.custom_field_name) }
                    .mapNotNull { it.editText }
                assertTrue(names.filter { it.text.toString() in listOf("Username", "Region") }.all { !it.isEnabled })
            }
        }
    }

    @Test
    fun editorPreservesUnsavedFieldsAcrossFoldChangesAndAvoidsVerticalHinge() {
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            var hinge = Rect()
            scenario.onActivity { activity ->
                unlockFixture(activity)
                openEditor(activity)
            }
            idle()
            capture("editor-before-fold")
            scenario.onActivity { activity ->
                val inputs = descendants(editor(activity).window!!.decorView).filterIsInstance<EditText>()
                inputs.first().setText("Unsaved fold draft")
                inputs.last().setText("Unsaved field value")
                val width = activity.window.decorView.width
                hinge = Rect(width * 2 / 5 - 12, 0, width * 2 / 5 + 12, activity.window.decorView.height)
                folding.overrideWindowLayoutInfo(WindowLayoutInfo(listOf(testFoldingFeature(
                    activity, center = width * 2 / 5, size = 24, orientation = FoldingFeature.Orientation.VERTICAL,
                ))))
            }
            idle()
            capture("editor-vertical-hinge")
            scenario.onActivity { activity ->
                val dialog = editor(activity)
                assertTrue(dialog.isShowing)
                val inputs = descendants(dialog.window!!.decorView).filterIsInstance<EditText>()
                assertEquals("Unsaved fold draft", inputs.first().text.toString())
                assertEquals("Unsaved field value", inputs.last().text.toString())
                assertOutsideHinge(dialog.window!!.decorView, hinge)
                val body = dialog.window!!.decorView.findViewWithTag<LinearLayout>("entry_editor_body")
                assertEquals(LinearLayout.VERTICAL, body.orientation)
                assertMainPanesOutsideHinge(activity, hinge)
                folding.overrideWindowLayoutInfo(WindowLayoutInfo(emptyList()))
            }
            idle()
            scenario.onActivity { activity ->
                val inputs = descendants(editor(activity).window!!.decorView).filterIsInstance<EditText>()
                assertEquals("Unsaved fold draft", inputs.first().text.toString())
                assertEquals("Unsaved field value", inputs.last().text.toString())
            }
        }
    }

    @Test
    fun keyboardKeepsEditorActionsAboveIme() {
        org.junit.Assume.assumeTrue(android.os.Build.VERSION.SDK_INT >= 30)
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            scenario.onActivity { activity ->
                unlockFixture(activity)
                openEditor(activity)
            }
            idle()
            scenario.onActivity { activity ->
                val dialog = editor(activity)
                descendants(dialog.window!!.decorView).filterIsInstance<EditText>().first().requestFocus()
                dialog.window!!.insetsController!!.show(WindowInsets.Type.ime())
            }
            idle()
            Thread.sleep(800)
            scenario.onActivity { activity ->
                val dialog = editor(activity)
                val decor = dialog.window!!.decorView
                val insets = decor.rootWindowInsets
                assertTrue("Keyboard must actually be visible", insets.isVisible(WindowInsets.Type.ime()))
                val windowHeight = activity.windowManager.currentWindowMetrics.bounds.height()
                val keyboardTop = windowHeight - insets.getInsets(WindowInsets.Type.ime()).bottom
                for (button in listOf(dialog.getButton(AlertDialog.BUTTON_POSITIVE), dialog.getButton(AlertDialog.BUTTON_NEGATIVE))) {
                    val location = IntArray(2)
                    button.getLocationOnScreen(location)
                    assertTrue("Editor action at ${location[1] + button.height} overlaps keyboard at $keyboardTop",
                        location[1] + button.height <= keyboardTop)
                    assertTrue(button.getGlobalVisibleRect(Rect()))
                }
                dialog.window!!.insetsController!!.hide(WindowInsets.Type.ime())
            }
        }
    }

    @Test
    fun tabletopUsesActualHingeBoundsAndKeepsEditorActionsVisible() {
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            var hinge = Rect()
            scenario.onActivity { activity ->
                unlockFixture(activity)
                val height = activity.window.decorView.height
                hinge = Rect(0, height * 2 / 5 - 12, activity.window.decorView.width, height * 2 / 5 + 12)
                folding.overrideWindowLayoutInfo(WindowLayoutInfo(listOf(testFoldingFeature(
                    activity, center = height * 2 / 5, size = 24, orientation = FoldingFeature.Orientation.HORIZONTAL,
                ))))
            }
            idle()
            scenario.onActivity { activity ->
                assertMainPanesOutsideHinge(activity, hinge)
                openEditor(activity)
            }
            idle()
            capture("editor-tabletop")
            scenario.onActivity { activity ->
                val dialog = editor(activity)
                assertOutsideHinge(dialog.window!!.decorView, hinge)
                val save = dialog.getButton(AlertDialog.BUTTON_POSITIVE)
                val cancel = dialog.getButton(AlertDialog.BUTTON_NEGATIVE)
                assertTrue(save.isShown && cancel.isShown)
                assertTrue(save.height >= (48 * activity.resources.displayMetrics.density).toInt())
                assertOutsideHinge(save, hinge)
                assertOutsideHinge(cancel, hinge)
            }
        }
    }

    private fun unlockFixture(activity: MainActivity) {
        assertTrue(store(activity).setupMasterPassword("FixturePassword123!", "FixturePassword123!"))
        store(activity).upsert(EntryDraft(
            label = "GitHub", type = VaultEntryType.CREDENTIAL, category = "Accounts", tags = emptyList(),
            customFields = listOf(CustomField(name = "Username", value = "demo@example.com")),
        ))
        MainActivity::class.java.getDeclaredMethod("showHome", Boolean::class.javaPrimitiveType)
            .apply { isAccessible = true }.invoke(activity, false)
    }

    private fun openEditor(activity: MainActivity) {
        MainActivity::class.java.getDeclaredMethod(
            "showEditor", VaultEntry::class.java, String::class.java, String::class.java, String::class.java,
        ).apply { isAccessible = true }.invoke(activity, null, "", "", null)
    }

    private fun store(activity: MainActivity): VaultStore =
        MainActivity::class.java.getDeclaredField("store").apply { isAccessible = true }.get(activity) as VaultStore

    @Suppress("UNCHECKED_CAST")
    private fun editor(activity: MainActivity): AlertDialog =
        (MainActivity::class.java.getDeclaredField("trackedDialogs").apply { isAccessible = true }
            .get(activity) as Set<AlertDialog>).last { it.isShowing }

    private fun assertMainPanesOutsideHinge(activity: MainActivity, hinge: Rect) {
        val root = activity.findViewById<ViewGroup>(android.R.id.content).getChildAt(0) as ViewGroup
        assertEquals(2, root.childCount)
        for (index in 0 until root.childCount) assertOutsideHinge(root.getChildAt(index), hinge)
    }

    private fun assertOutsideHinge(view: View, hinge: Rect) {
        val location = IntArray(2)
        view.getLocationOnScreen(location)
        val bounds = Rect(location[0], location[1], location[0] + view.width, location[1] + view.height)
        assertTrue("Expected measured bounds: $bounds", bounds.width() > 0 && bounds.height() > 0)
        assertFalse("View $bounds overlaps hinge $hinge", Rect.intersects(bounds, hinge))
    }

    private fun descendants(view: View): List<View> = listOf(view) +
        if (view is ViewGroup) (0 until view.childCount).flatMap { descendants(view.getChildAt(it)) } else emptyList()

    private fun capture(name: String) {
        val folder = File(instrumentation.targetContext.cacheDir, "ui-regression").apply { mkdirs() }
        File(folder, "$name.png").outputStream().use { stream ->
            instrumentation.uiAutomation.takeScreenshot().compress(Bitmap.CompressFormat.PNG, 100, stream)
        }
    }

    private fun idle() {
        instrumentation.waitForIdleSync()
        // Window-info collection, View reparenting, and WindowManager resizing each post a frame.
        Thread.sleep(350)
        instrumentation.waitForIdleSync()
    }
}
