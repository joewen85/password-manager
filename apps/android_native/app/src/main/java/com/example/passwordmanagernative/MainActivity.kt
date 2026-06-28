package com.example.passwordmanagernative

import android.app.Activity
import android.app.AlertDialog
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.res.ColorStateList
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.net.Uri
import android.os.Bundle
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.text.Editable
import android.text.InputType
import android.text.TextWatcher
import android.view.Gravity
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsets
import android.widget.ArrayAdapter
import android.widget.Button
import android.widget.CheckBox
import android.widget.EditText
import android.widget.ImageButton
import android.widget.ImageView
import android.widget.HorizontalScrollView
import android.widget.LinearLayout
import android.widget.PopupWindow
import android.widget.ScrollView
import android.widget.Spinner
import android.widget.TextView
import android.widget.Toast
import androidx.biometric.BiometricManager.Authenticators.BIOMETRIC_STRONG
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import androidx.window.layout.FoldingFeature
import androidx.window.layout.WindowLayoutInfo
import androidx.window.layout.WindowInfoTracker
import com.example.passwordmanagernative.model.CredentialPayload
import com.example.passwordmanagernative.model.CategoryTemplate
import com.example.passwordmanagernative.model.CategoryTypePreset
import com.example.passwordmanagernative.model.CustomField
import com.example.passwordmanagernative.model.EntryDraft
import com.example.passwordmanagernative.model.ImportConflictStrategy
import com.example.passwordmanagernative.model.ServerPayload
import com.example.passwordmanagernative.model.ServiceAccount
import com.example.passwordmanagernative.model.ServicePayload
import com.example.passwordmanagernative.model.VaultEntry
import com.example.passwordmanagernative.model.VaultEntryType
import com.example.passwordmanagernative.model.VaultPayload
import com.example.passwordmanagernative.store.BiometricCredentialStore
import com.example.passwordmanagernative.store.BackupInfo
import com.example.passwordmanagernative.store.VaultStore
import com.example.passwordmanagernative.sync.AutoSyncSchedulePolicy
import com.example.passwordmanagernative.sync.SyncLogEntry
import com.example.passwordmanagernative.sync.SyncIntervalUnit
import com.example.passwordmanagernative.sync.SyncProviderType
import com.example.passwordmanagernative.sync.SyncSettingsConflictStrategy
import com.example.passwordmanagernative.sync.toIntervalMinutes
import com.example.passwordmanagernative.store.withTemplateDefaults
import com.example.passwordmanagernative.ui.WindowLayoutPolicy
import life.devops.passwordmanager.R
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.Instant
import java.time.ZoneId
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter

class MainActivity : FragmentActivity() {
    private lateinit var store: VaultStore
    private lateinit var biometricCredentialStore: BiometricCredentialStore
    private lateinit var appPreferences: SharedPreferences
    private lateinit var searchField: EditText
    private var entriesContainer: LinearLayout? = null
    private var entriesScrollView: ScrollView? = null
    private var detailPane: LinearLayout? = null
    private var selectedEntry: VaultEntry? = null
    private var selectedType: VaultEntryType? = null
    private var selectedCategory: String? = null
    private var selectedTag: String? = null
    private var searchQuery: String = ""
    private var pendingExportJson: String? = null
    private var pendingImportKind: PendingImportKind? = null
    private var pendingImportStrategy: ImportConflictStrategy = ImportConflictStrategy.KEEP_COPY
    private var activeTaxonomyListDialog: AlertDialog? = null
    private var biometricFailureCount: Int = 0
    private var biometricPromptInFlight: Boolean = false
    private var biometricFallbackRequired: Boolean = false
    private var currentBiometricPrompt: BiometricPrompt? = null
    private var lastUserActivityAt: Long = System.currentTimeMillis()
    private var lastAutoSyncAttemptAt: Instant? = null
    private var lastAutoSyncUnlockState: Boolean = false
    private var activeSyncJob: Job? = null
    private val idleLockHandler = Handler(Looper.getMainLooper())
    private val idleLockRunnable = object : Runnable {
        override fun run() {
            checkIdleAutoLock()
            idleLockHandler.postDelayed(this, IdleLockCheckIntervalMs)
        }
    }
    private val autoSyncHandler = Handler(Looper.getMainLooper())
    private val autoSyncRunnable = object : Runnable {
        override fun run() {
            runAutoSyncIfNeeded()
            autoSyncHandler.postDelayed(this, AutoSyncCheckIntervalMs)
        }
    }
    private val layoutScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var windowLayoutInfo: WindowLayoutInfo? = null
    private var windowLayoutJob: Job? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        store = VaultStore(this)
        biometricCredentialStore = BiometricCredentialStore(this)
        appPreferences = getSharedPreferences(AppPreferencesName, Context.MODE_PRIVATE)
        observeWindowLayout()
        idleLockHandler.postDelayed(idleLockRunnable, IdleLockCheckIntervalMs)
        autoSyncHandler.postDelayed(autoSyncRunnable, AutoSyncCheckIntervalMs)
        showUnlock()
    }

    override fun onDestroy() {
        idleLockHandler.removeCallbacks(idleLockRunnable)
        autoSyncHandler.removeCallbacks(autoSyncRunnable)
        windowLayoutJob?.cancel()
        layoutScope.cancel()
        super.onDestroy()
    }

    override fun onResume() {
        super.onResume()
        checkIdleAutoLock()
        runAutoSyncIfNeeded()
    }

    override fun dispatchTouchEvent(ev: MotionEvent?): Boolean {
        markUserActivity()
        return super.dispatchTouchEvent(ev)
    }

    override fun dispatchKeyEvent(event: KeyEvent?): Boolean {
        markUserActivity()
        return super.dispatchKeyEvent(event)
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        if (store.isUnlocked) {
            showHome()
        } else {
            showUnlock()
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (resultCode != RESULT_OK) {
            return
        }
        val uri = data?.data ?: return
        when (requestCode) {
            RequestCodeCreateDocument -> writePendingExport(uri)
            RequestCodeOpenDocument -> readSelectedImport(uri)
        }
    }

    private fun showUnlock() {
        val page = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(dp(24), dp(24), dp(24), dp(24))
            setBackgroundColor(uiColor(R.color.ui_background))
        }
        val card = card().apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(24), dp(24), dp(24), dp(24))
            minimumWidth = dp(320)
        }
        val titleText = if (store.hasMasterKey) text(R.string.unlock_vault) else text(R.string.initialize_vault)
        card.addView(label(titleText, 28f, uiColor(R.color.ui_text), Typeface.BOLD))
        card.addView(label(text(R.string.app_name), 14f, uiColor(R.color.ui_muted)).apply {
            setPadding(0, dp(4), 0, dp(22))
        })

        val password = input(text(R.string.master_password), secret = true)
        val confirmation = input(text(R.string.confirm_master_password), secret = true).apply {
            visibility = if (store.hasMasterKey) View.GONE else View.VISIBLE
        }
        val totp = input(text(R.string.totp_code), inputType = InputType.TYPE_CLASS_NUMBER).apply {
            visibility = if (store.hasMasterKey && store.requireTotp) View.VISIBLE else View.GONE
        }
        val submit = actionButton(
            if (store.hasMasterKey) text(R.string.unlock) else text(R.string.create_vault),
            primary = true
        ) {
            val enteredPassword = password.text.toString()
            val success = if (store.hasMasterKey) {
                store.unlock(enteredPassword, totp.text.toString())
            } else {
                store.setupMasterPassword(enteredPassword, confirmation.text.toString())
            }
            if (success) {
                biometricFallbackRequired = false
                biometricFailureCount = 0
                handlePasswordUnlockSuccess(enteredPassword)
            } else {
                toast(store.statusMessage ?: text(R.string.operation_failed))
            }
        }

        card.addView(password, matchWrap(top = dp(8)))
        card.addView(confirmation, matchWrap(top = dp(10)))
        card.addView(totp, matchWrap(top = dp(10)))
        card.addView(submit, matchWrap(top = dp(18)))
        if (
            store.hasMasterKey &&
            isBiometricUnlockEnabled() &&
            !biometricFallbackRequired &&
            biometricCredentialStore.hasSavedCredential() &&
            biometricCredentialStore.canAuthenticate()
        ) {
            card.addView(actionButton(text(R.string.biometric_unlock), primary = false) {
                authenticateBiometricUnlock(totp.text.toString())
            }, matchWrap(top = dp(10)))
        }
        store.statusMessage?.let { message ->
            card.addView(label(message, 13f, uiColor(R.color.ui_muted)).apply {
                setPadding(0, dp(14), 0, 0)
            })
        }
        page.addView(card, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.WRAP_CONTENT
        ).apply {
            marginStart = dp(8)
            marginEnd = dp(8)
            width = resources.displayMetrics.widthPixels.coerceAtMost(dp(520))
        })
        setContentViewWithSystemBars(page)
        maybeStartAutoBiometricUnlock(totp.text.toString())
    }

    private fun handlePasswordUnlockSuccess(password: String) {
        markUserActivity()
        showHome()
        syncOnUnlockIfNeeded()
    }

    private fun authenticateBiometricUnlock(totpCode: String, automatic: Boolean = false) {
        if (biometricPromptInFlight) return
        val cipher = biometricCredentialStore.createDecryptCipher() ?: run {
            toast(text(R.string.biometric_unlock_not_enabled))
            return
        }
        biometricPromptInFlight = true
        val prompt = BiometricPrompt(
            this,
            ContextCompat.getMainExecutor(this),
            object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                    biometricPromptInFlight = false
                    currentBiometricPrompt = null
                    biometricFailureCount = 0
                    biometricFallbackRequired = false
                    val authenticatedCipher = result.cryptoObject?.cipher ?: cipher
                    val password = runCatching {
                        biometricCredentialStore.readPassword(authenticatedCipher)
                    }.getOrElse {
                        biometricCredentialStore.clear()
                        setBiometricUnlockEnabled(false)
                        biometricFallbackRequired = true
                        toast(it.message ?: text(R.string.operation_failed))
                        return
                    }
                    toast(text(R.string.unlocking_vault))
                    layoutScope.launch {
                        val resultMessage = withContext(Dispatchers.IO) {
                            if (store.unlock(password, totpCode)) {
                                UnlockResult(
                                    success = true,
                                    message = store.statusMessage ?: text(R.string.unlock),
                                )
                            } else {
                                UnlockResult(
                                    success = false,
                                    message = store.statusMessage ?: text(R.string.operation_failed),
                                )
                            }
                        }
                        if (resultMessage.success) {
                            markUserActivity()
                            showHome()
                            syncOnUnlockIfNeeded()
                        } else {
                            biometricFallbackRequired = true
                        }
                        toast(resultMessage.message)
                    }
                }

                override fun onAuthenticationFailed() {
                    biometricFailureCount += 1
                    if (biometricFailureCount >= MaxBiometricFailures) {
                        biometricFallbackRequired = true
                        biometricPromptInFlight = false
                        toast(text(R.string.biometric_fallback_required))
                        currentBiometricPrompt?.cancelAuthentication()
                        currentBiometricPrompt = null
                        showUnlock()
                    }
                }

                override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                    biometricPromptInFlight = false
                    currentBiometricPrompt = null
                    if (!automatic) {
                        toast(errString.toString())
                    }
                }
            }
        )
        currentBiometricPrompt = prompt
        prompt.authenticate(biometricPromptInfo(text(R.string.biometric_unlock)), BiometricPrompt.CryptoObject(cipher))
    }

    private fun enableBiometricUnlock(password: String) {
        val cipher = runCatching { biometricCredentialStore.createEncryptCipher() }.getOrElse {
            toast(it.message ?: text(R.string.operation_failed))
            return
        }
        val prompt = BiometricPrompt(
            this,
            ContextCompat.getMainExecutor(this),
            object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                    currentBiometricPrompt = null
                    val authenticatedCipher = result.cryptoObject?.cipher ?: cipher
                    runCatching {
                        biometricCredentialStore.savePassword(authenticatedCipher, password)
                        setBiometricUnlockEnabled(true)
                        biometricFallbackRequired = false
                        biometricFailureCount = 0
                        toast(text(R.string.biometric_unlock_enabled))
                    }.onFailure {
                        toast(it.message ?: text(R.string.operation_failed))
                    }
                }

                override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                    currentBiometricPrompt = null
                    toast(errString.toString())
                }
            }
        )
        currentBiometricPrompt = prompt
        prompt.authenticate(
            biometricPromptInfo(text(R.string.enable_biometric_unlock)),
            BiometricPrompt.CryptoObject(cipher),
        )
    }

    private fun maybeStartAutoBiometricUnlock(totpCode: String) {
        if (!store.hasMasterKey || store.requireTotp || biometricFallbackRequired || biometricPromptInFlight) {
            return
        }
        if (!isBiometricUnlockEnabled() || !biometricCredentialStore.hasSavedCredential() || !biometricCredentialStore.canAuthenticate()) {
            return
        }
        window.decorView.post {
            if (!store.isUnlocked && !biometricFallbackRequired) {
                authenticateBiometricUnlock(totpCode, automatic = true)
            }
        }
    }

    private fun biometricPromptInfo(title: String): BiometricPrompt.PromptInfo =
        BiometricPrompt.PromptInfo.Builder()
            .setTitle(title)
            .setSubtitle(text(R.string.biometric_unlock_prompt))
            .setNegativeButtonText(text(R.string.cancel))
            .setAllowedAuthenticators(BIOMETRIC_STRONG)
            .build()

    private fun showHome(preserveEntryScroll: Boolean = false) {
        val entryScrollAnchor = if (preserveEntryScroll) captureEntryScrollAnchor() else null
        val foldInfo = currentFoldInfo()
        val expandedLayout = isExpandedLayout(foldInfo)
        val tabletopLayout = foldInfo?.isHorizontalSeparating == true
        val page = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(uiColor(R.color.ui_background))
        }
        page.addView(topBar(), matchWrap())
        page.addView(statusSummary(), matchWrap(left = dp(16), right = dp(16), top = dp(8)))

        val body = LinearLayout(this).apply {
            orientation = if (expandedLayout && !tabletopLayout) LinearLayout.HORIZONTAL else LinearLayout.VERTICAL
            setPadding(dp(16), dp(14), dp(16), dp(16))
        }

        val listPane = listPane()
        if (expandedLayout && !tabletopLayout) {
            body.addView(listPane, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, 1.0f))
            detailPane = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(dp(14), 0, 0, 0)
            }
            body.addView(detailPane, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, 1.35f))
        } else if (expandedLayout) {
            body.addView(listPane, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1.0f))
            detailPane = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(0, dp(14), 0, 0)
            }
            body.addView(detailPane, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1.0f))
        } else {
            body.addView(listPane, LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                0,
                1f
            ))
            detailPane = null
        }

        page.addView(body, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            0,
            1f
        ))
        setContentViewWithSystemBars(page)
        refreshEntries()
        restoreEntryScrollAnchor(entryScrollAnchor)
        if (expandedLayout) {
            renderDetailPane(selectedEntry)
        }
    }

    private fun topBar(): LinearLayout =
        LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(16), dp(10), dp(16), dp(8))
            addView(LinearLayout(this@MainActivity).apply {
                orientation = LinearLayout.VERTICAL
                addView(label(text(R.string.app_name), 19f, uiColor(R.color.ui_text), Typeface.BOLD))
                addView(securityTag(text(R.string.native_android_vault)), wrapWrap(top = dp(4)))
            }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
            addView(toolbarIconButton(R.drawable.ic_add_24, text(R.string.create_label), accent = true) {
                showCreateMenu(it)
            }, wrapWrap(right = dp(2)))
            addView(toolbarIconButton(R.drawable.ic_sync_24, text(R.string.sync)) {
                runSync()
            }, wrapWrap(right = dp(2)))
            addView(toolbarIconButton(R.drawable.ic_cloud_upload_24, text(R.string.backups)) {
                showBackupCenter(it)
            }, wrapWrap(right = dp(2)))
            addView(toolbarIconButton(R.drawable.ic_more_vertical_24, text(R.string.more_actions)) {
                showMoreActions(it)
            }, wrapWrap(right = dp(2)))
            addView(toolbarIconButton(R.drawable.ic_lock_24, text(R.string.lock)) {
                lockVaultAndShowUnlock()
            }, wrapWrap())
        }

    private fun statusSummary(): LinearLayout {
        val activeCount = store.listEntries().size
        val categoryCount = store.categories().size
        return LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            background = rounded(uiColor(R.color.ui_surface_alt), compactRadius(), uiColor(R.color.ui_stroke))
            setPadding(dp(10), 0, dp(10), 0)
            minimumHeight = compactControlHeight()
            addView(label(
                "${text(R.string.entries)} $activeCount · ${text(R.string.categories)} $categoryCount · ${text(R.string.sync)} ${store.syncStatus}",
                11f,
                uiColor(R.color.ui_muted)
            ).apply {
                maxLines = 1
                ellipsize = android.text.TextUtils.TruncateAt.END
            }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        }
    }

    private fun listPane(): LinearLayout =
        card().apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(14), dp(12), dp(14), dp(14))
            addView(categoryChipStrip(), matchWrap())
            searchField = filterSearchInput(text(R.string.search_vault_scoped)).apply {
                setSingleLine(true)
                setText(searchQuery)
                addTextChangedListener(object : TextWatcher {
                    override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
                    override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {
                        searchQuery = s?.toString().orEmpty()
                        refreshEntries()
                    }
                    override fun afterTextChanged(s: Editable?) = Unit
                })
                setOnEditorActionListener { _, _, _ ->
                    refreshEntries()
                    true
                }
            }
            addView(searchBox(searchField), matchWrap(top = dp(16)))
            addView(tagChipStrip(), matchWrap(top = dp(16)))

            entriesContainer = LinearLayout(this@MainActivity).apply {
                orientation = LinearLayout.VERTICAL
            }
            entriesScrollView = ScrollView(this@MainActivity).apply {
                isFillViewport = true
                addView(entriesContainer)
            }
            addView(entriesScrollView, LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                0,
                1f
            ).apply {
                topMargin = dp(10)
            })
        }

    private fun actionStrip(): HorizontalScrollView =
        HorizontalScrollView(this).apply {
            isHorizontalScrollBarEnabled = false
            addView(LinearLayout(this@MainActivity).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                addView(toolbarIconButton(R.drawable.ic_add_24, text(R.string.create_label), accent = true) {
                    showCreateMenu(it)
                }, wrapWrap(right = dp(4)))
                addView(toolbarIconButton(R.drawable.ic_sync_24, text(R.string.sync)) {
                    runSync()
                }, wrapWrap(right = dp(4)))
                addView(toolbarIconButton(R.drawable.ic_cloud_upload_24, text(R.string.backups)) {
                    showBackupCenter(it)
                }, wrapWrap(right = dp(4)))
                addView(toolbarIconButton(R.drawable.ic_more_vertical_24, text(R.string.more_actions)) {
                    showMoreActions(it)
                }, wrapWrap())
            })
        }

    private fun categoryChipStrip(): HorizontalScrollView =
        HorizontalScrollView(this).apply {
            isHorizontalScrollBarEnabled = false
            addView(LinearLayout(this@MainActivity).apply {
                orientation = LinearLayout.HORIZONTAL
                addView(filterChip(text(R.string.all_categories), selectedCategory == null, showCheck = true) {
                    selectedType = null
                    selectedCategory = null
                    showHome()
                }, wrapWrap(right = dp(8)))
                store.categories().forEach { category ->
                    addView(filterChip(category, selectedCategory == category) {
                        selectedType = null
                        selectedCategory = category
                        showHome()
                    }, wrapWrap(right = dp(8)))
                }
            })
        }

    private fun tagChipStrip(): LinearLayout =
        LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            val tags = store.tags()
            val visibleTags = tags.take(if (isCompactWidth()) 3 else 4)
            addView(HorizontalScrollView(this@MainActivity).apply {
                isHorizontalScrollBarEnabled = false
                addView(LinearLayout(this@MainActivity).apply {
                    orientation = LinearLayout.HORIZONTAL
                    addView(filterChip(text(R.string.all), selectedTag == null, showCheck = true) {
                        selectedTag = null
                        showHome()
                    }, wrapWrap(right = dp(8)))
                    visibleTags.forEach { tag ->
                        addView(filterChip(tag, selectedTag == tag) {
                            selectedTag = tag
                            showHome()
                        }, wrapWrap(right = dp(8)))
                    }
                })
            }, matchWrap())
            val hiddenCount = tags.size - visibleTags.size
            if (hiddenCount > 0) {
                addView(filterChip(text(R.string.more_count, hiddenCount), selected = false) {
                    showTagSelectionDialog(tags, selectedTag?.let(::setOf).orEmpty()) { selected ->
                        selectedTag = selected.firstOrNull()
                        showHome()
                    }
                }, wrapWrap(top = dp(12)))
            }
        }

    private fun searchBox(input: EditText): LinearLayout =
        LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            minimumHeight = filterSearchHeight()
            setPadding(dp(14), 0, dp(14), 0)
            background = rounded(uiColor(R.color.ui_surface_alt), dp(14), uiColor(R.color.ui_stroke))
            addView(label("⌕", 24f, uiColor(R.color.ui_text)), wrapWrap(right = dp(12)))
            addView(input, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, 1f))
            addView(label("?", 18f, uiColor(R.color.ui_muted), Typeface.BOLD).apply {
                gravity = Gravity.CENTER
                background = rounded(Color.TRANSPARENT, dp(999), uiColor(R.color.ui_muted))
                isClickable = true
                isFocusable = true
                setOnClickListener {
                    showSearchSyntaxPopup(this)
                }
            }, LinearLayout.LayoutParams(dp(26), dp(26)))
        }

    private fun showSearchSyntaxPopup(anchor: View) {
        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(14), dp(12), dp(14), dp(12))
            addView(label(text(R.string.search_syntax_title), 15f, uiColor(R.color.ui_text), Typeface.BOLD))
            addView(label(text(R.string.search_syntax_body), 13f, uiColor(R.color.ui_muted)).apply {
                setPadding(0, dp(8), 0, 0)
            })
        }
        showAnchoredPopup(anchor, content, maxWidth = dp(300))
    }

    private fun refreshEntries() {
        val container = entriesContainer ?: return
        val query = searchField.text?.toString().orEmpty()
        val visibleEntries = store.listEntries(
            query = query,
            type = selectedType,
            category = selectedCategory,
            tag = selectedTag,
        )
        container.removeAllViews()
        if (visibleEntries.isEmpty()) {
            container.addView(emptyState(), matchWrap())
        } else {
            visibleEntries.forEach { entry ->
                container.addView(entryRow(entry), matchWrap(bottom = dp(10)))
            }
        }
        val stillVisible = selectedEntry?.let { selected ->
            visibleEntries.firstOrNull { it.id == selected.id }
        }
        selectedEntry = stillVisible
        if (detailPane != null) {
            renderDetailPane(stillVisible)
        }
    }

    private fun emptyState(): LinearLayout =
        LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(dp(24), dp(56), dp(24), dp(56))
            addView(label(text(R.string.no_entries), 20f, uiColor(R.color.ui_text), Typeface.BOLD))
            addView(label(text(R.string.no_entries_description), 14f, uiColor(R.color.ui_muted)).apply {
                setPadding(0, dp(6), 0, dp(14))
            })
            addView(actionButton(text(R.string.new_entry), primary = true) { showEditor(null) }, wrapWrap())
        }

    private fun entryRow(entry: VaultEntry): LinearLayout {
        val selected = selectedEntry?.id == entry.id
        return LinearLayout(this).apply {
            tag = entry.id
            orientation = LinearLayout.VERTICAL
            isClickable = true
            isFocusable = true
            background = rounded(if (selected) uiColor(R.color.ui_selected) else uiColor(R.color.ui_surface_alt), dp(14), if (selected) uiColor(R.color.ui_accent) else uiColor(R.color.ui_stroke))
            setPadding(dp(14), dp(12), dp(14), dp(12))
            addView(LinearLayout(this@MainActivity).apply {
                gravity = Gravity.CENTER_VERTICAL
                addView(label(entry.label.ifBlank { text(R.string.untitled) }, 16f, uiColor(R.color.ui_text), Typeface.BOLD), LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
            })
            val meta = buildString {
                append(entry.payload.category.ifBlank { text(R.string.uncategorized) })
                if (entry.payload.tags.isNotEmpty()) {
                    append("  ")
                    append(entry.payload.tags.joinToString(", ") { "#$it" })
                }
            }
            addView(label(meta, 13f, uiColor(R.color.ui_muted)).apply {
                setPadding(0, dp(6), 0, 0)
                maxLines = 2
            })
            setOnClickListener {
                selectedEntry = entry
                showDetail(entry)
                refreshEntries()
            }
        }
    }

    private fun showDetail(entry: VaultEntry?) {
        if (entry == null) return
        if (detailPane != null) {
            selectedEntry = entry
            renderDetailPane(entry)
            return
        }
        lateinit var dialog: AlertDialog
        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(18), dp(20), dp(6))
            addView(LinearLayout(this@MainActivity).apply {
                gravity = Gravity.END
                addView(compactTextButton(text(R.string.close)) { dialog.dismiss() }, wrapWrap())
            }, matchWrap(bottom = compactGap()))
            addView(detailContent(entry))
        }
        dialog = AlertDialog.Builder(this)
            .setView(ScrollView(this).apply { addView(content) })
            .setPositiveButton(text(R.string.edit)) { _, _ -> showEditor(entry) }
            .setNegativeButton(text(R.string.delete)) { _, _ ->
                store.delete(entry.id)
                selectedEntry = null
                refreshEntries()
            }
            .setNeutralButton(text(R.string.export)) { _, _ ->
                showEntryExportFieldDialog(entry)
            }
            .show()
    }

    private fun showCreateMenu(anchor: View? = null) {
        val form = formRoot()
        form.addView(formTitle(text(R.string.create_label)))
        form.addView(label(text(R.string.create_entry_menu_hint), 13f, uiColor(R.color.ui_muted)), matchWrap(top = dp(8)))
        var popup: PopupWindow? = null
        form.addView(actionButton(text(R.string.create_entry), primary = true) {
            popup?.dismiss()
            showEditor(null)
        }, matchWrap(top = dp(14)))
        form.addView(actionButton(text(R.string.create_category), primary = false) {
            popup?.dismiss()
            showTaxonomyInputDialog(TaxonomyKind.CATEGORY)
        }, matchWrap(top = dp(10)))
        form.addView(actionButton(text(R.string.create_tag), primary = false) {
            popup?.dismiss()
            showTaxonomyInputDialog(TaxonomyKind.TAG)
        }, matchWrap(top = dp(10)))
        popup = showAnchoredPopup(anchor, form)
    }

    private fun showMoreActions(anchor: View? = null) {
        val form = formRoot()
        form.addView(formTitle(text(R.string.more_actions)))
        var popup: PopupWindow? = null
        form.addView(actionButton(text(R.string.export), primary = false) {
            popup?.dismiss()
            showExportDialog()
        }, matchWrap(top = dp(12)))
        form.addView(actionButton(text(R.string.import_label), primary = false) {
            popup?.dismiss()
            showImportCenterDialog()
        }, matchWrap(top = dp(10)))
        form.addView(actionButton(text(R.string.settings), primary = false) {
            popup?.dismiss()
            showSettings()
        }, matchWrap(top = dp(10)))
        form.addView(actionButton(text(R.string.manage_taxonomy), primary = false) {
            popup?.dismiss()
            showTaxonomyManager()
        }, matchWrap(top = dp(10)))
        form.addView(actionButton(text(R.string.clear_data), primary = false) {
            popup?.dismiss()
            showClearDataDialog()
        }, matchWrap(top = dp(10)))
        popup = showAnchoredPopup(anchor, form)
    }

    private fun showTaxonomyManager() {
        val form = formRoot()
        form.addView(formTitle(text(R.string.manage_taxonomy)))
        form.addView(label(text(R.string.manage_taxonomy_hint), 13f, uiColor(R.color.ui_muted)), matchWrap(top = dp(8)))
        form.addView(actionButton(text(R.string.manage_categories), primary = false) {
            showTaxonomyListEditor(TaxonomyKind.CATEGORY)
        }, matchWrap(top = dp(14)))
        form.addView(actionButton(text(R.string.manage_tags), primary = false) {
            showTaxonomyListEditor(TaxonomyKind.TAG)
        }, matchWrap(top = dp(10)))
        AlertDialog.Builder(this)
            .setView(form)
            .setNegativeButton(text(R.string.close), null)
            .show()
    }

    private fun showClearDataDialog() {
        val form = formRoot()
        val password = input(text(R.string.master_password), secret = true)
        form.addView(formTitle(text(R.string.clear_data)))
        form.addView(label(text(R.string.clear_data_warning), 13f, uiColor(R.color.ui_muted)), matchWrap(top = dp(8)))
        form.addView(password, matchWrap(top = dp(14)))
        val dialog = AlertDialog.Builder(this)
            .setView(form)
            .setPositiveButton(text(R.string.clear_data_confirm), null)
            .setNegativeButton(text(R.string.cancel), null)
            .create()
        dialog.setOnShowListener {
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
                if (password.text.toString().isBlank()) {
                    toast(text(R.string.value_required))
                    return@setOnClickListener
                }
                if (!store.clearAllData(password.text.toString())) {
                    toast(store.statusMessage ?: text(R.string.operation_failed))
                    return@setOnClickListener
                }
                biometricCredentialStore.clear()
                selectedEntry = null
                selectedType = null
                selectedCategory = null
                selectedTag = null
                searchQuery = ""
                dialog.dismiss()
                showHome()
                toast(store.statusMessage ?: text(R.string.clear_data_complete))
            }
        }
        dialog.show()
    }

    private fun showTaxonomyListEditor(kind: TaxonomyKind) {
        activeTaxonomyListDialog?.dismiss()
        val form = formRoot()
        val title = when (kind) {
            TaxonomyKind.CATEGORY -> text(R.string.manage_categories)
            TaxonomyKind.TAG -> text(R.string.manage_tags)
        }
        val values = when (kind) {
            TaxonomyKind.CATEGORY -> store.categories()
            TaxonomyKind.TAG -> store.tags()
        }
        form.addView(formTitle(title))
        form.addView(label(text(R.string.manage_taxonomy_list_hint), 13f, uiColor(R.color.ui_muted)), matchWrap(top = dp(8)))
        form.addView(actionButton(text(R.string.create_label), primary = true) {
            showTaxonomyInputDialog(kind, onSaved = { showTaxonomyListEditor(kind) }, returnToHomeAfterSave = false)
        }, matchWrap(top = dp(12)))
        if (values.isEmpty()) {
            form.addView(label(text(R.string.none), 13f, uiColor(R.color.ui_muted)), matchWrap(top = dp(12)))
        } else {
            values.forEach { value ->
                form.addView(taxonomyRow(kind, value), matchWrap(top = dp(8)))
            }
        }
        activeTaxonomyListDialog = AlertDialog.Builder(this)
            .setView(ScrollView(this).apply { addView(form) })
            .setNegativeButton(text(R.string.close), null)
            .show()
            .also { dialog ->
                dialog.setOnDismissListener {
                    if (activeTaxonomyListDialog == dialog) {
                        activeTaxonomyListDialog = null
                    }
                }
            }
    }

    private fun taxonomyRow(kind: TaxonomyKind, value: String): LinearLayout =
        LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = rounded(uiColor(R.color.ui_surface_alt), dp(12), uiColor(R.color.ui_stroke))
            setPadding(dp(12), dp(10), dp(12), dp(10))
            addView(label(value, 14f, uiColor(R.color.ui_text), Typeface.BOLD))
            addView(LinearLayout(this@MainActivity).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.END
                addView(actionButton(text(R.string.rename), primary = false, compact = true) {
                    showRenameTaxonomyDialog(kind, value)
                }, wrapWrap(right = dp(8)))
                addView(actionButton(text(R.string.delete), primary = false, compact = true) {
                    confirmDeleteTaxonomy(kind, value)
                }, wrapWrap())
            }, matchWrap(top = dp(10)))
        }

    private fun showRenameTaxonomyDialog(kind: TaxonomyKind, oldValue: String) {
        val form = formRoot()
        val title = when (kind) {
            TaxonomyKind.CATEGORY -> text(R.string.rename_category)
            TaxonomyKind.TAG -> text(R.string.rename_tag)
        }
        val field = input(title).apply { setText(oldValue) }
        form.addView(formTitle(title))
        form.addView(field, matchWrap(top = dp(12)))
        AlertDialog.Builder(this)
            .setView(form)
            .setPositiveButton(text(R.string.save)) { _, _ ->
                val newValue = field.text.toString()
                val success = when (kind) {
                    TaxonomyKind.CATEGORY -> store.renameCategory(oldValue, newValue)
                    TaxonomyKind.TAG -> store.renameTag(oldValue, newValue)
                }
                if (success) {
                    activeTaxonomyListDialog?.dismiss()
                    showHome()
                    showTaxonomyListEditor(kind)
                    toast(store.statusMessage ?: text(R.string.saved))
                } else {
                    toast(store.statusMessage ?: text(R.string.operation_failed))
                }
            }
            .setNegativeButton(text(R.string.cancel), null)
            .show()
    }

    private fun confirmDeleteTaxonomy(kind: TaxonomyKind, value: String) {
        val title = when (kind) {
            TaxonomyKind.CATEGORY -> text(R.string.delete_category)
            TaxonomyKind.TAG -> text(R.string.delete_tag)
        }
        val message = when (kind) {
            TaxonomyKind.CATEGORY -> text(R.string.delete_category_confirm, value)
            TaxonomyKind.TAG -> text(R.string.delete_tag_confirm, value)
        }
        AlertDialog.Builder(this)
            .setTitle(title)
            .setMessage(message)
            .setPositiveButton(text(R.string.delete)) { _, _ ->
                val success = when (kind) {
                    TaxonomyKind.CATEGORY -> store.deleteCategory(value)
                    TaxonomyKind.TAG -> store.deleteTag(value)
                }
                if (success) {
                    if (selectedCategory.equals(value, ignoreCase = true)) {
                        selectedCategory = null
                    }
                    activeTaxonomyListDialog?.dismiss()
                    showHome()
                    showTaxonomyListEditor(kind)
                    toast(store.statusMessage ?: text(R.string.saved))
                } else {
                    toast(store.statusMessage ?: text(R.string.operation_failed))
                }
            }
            .setNegativeButton(text(R.string.cancel), null)
            .show()
    }

    private fun renderDetailPane(entry: VaultEntry?) {
        val pane = detailPane ?: return
        pane.removeAllViews()
        val detailCard = card().apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(18), dp(18), dp(18), dp(18))
        }
        if (entry == null) {
            detailCard.gravity = Gravity.CENTER
            detailCard.addView(label(text(R.string.select_entry), 24f, uiColor(R.color.ui_text), Typeface.BOLD))
            detailCard.addView(label(text(R.string.entry_details_hint), 14f, uiColor(R.color.ui_muted)).apply {
                setPadding(0, dp(6), 0, 0)
            })
            pane.addView(detailCard, LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT
            ))
            return
        }
        detailCard.addView(detailContent(entry), LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            0,
            1f
        ))
        detailCard.addView(LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.END
            addView(actionButton(text(R.string.export), primary = false) {
                showEntryExportFieldDialog(entry)
            }, wrapWrap(right = dp(8)))
            addView(actionButton(text(R.string.edit), primary = true) { showEditor(entry) }, wrapWrap(right = dp(8)))
            addView(actionButton(text(R.string.delete), primary = false) {
                store.delete(entry.id)
                selectedEntry = null
                refreshEntries()
            }, wrapWrap())
        }, matchWrap(top = dp(12)))
        pane.addView(detailCard, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.MATCH_PARENT
        ))
    }

    private fun detailContent(entry: VaultEntry): ScrollView =
        ScrollView(this).apply {
            addView(LinearLayout(this@MainActivity).apply {
                orientation = LinearLayout.VERTICAL
                addView(label(entry.label.ifBlank { text(R.string.untitled) }, 26f, uiColor(R.color.ui_text), Typeface.BOLD))
                addView(LinearLayout(this@MainActivity).apply {
                    orientation = LinearLayout.HORIZONTAL
                    setPadding(0, dp(8), 0, dp(14))
                    addView(pill(entry.payload.category.ifBlank { text(R.string.uncategorized) }, selected = false), wrapWrap())
                })
                if (entry.payload.tags.isNotEmpty()) {
                    addView(LinearLayout(this@MainActivity).apply {
                        orientation = LinearLayout.HORIZONTAL
                        setPadding(0, 0, 0, dp(12))
                        entry.payload.tags.forEachIndexed { index, tag ->
                            addView(pill("#$tag", selected = false), wrapWrap(right = if (index == entry.payload.tags.lastIndex) 0 else dp(8)))
                        }
                    })
                }
                addView(detailSection(text(R.string.overview), listOf(
                    text(R.string.updated) to entry.updatedAt.toString(),
                )))
                addView(detailSection(text(R.string.fields), entry.detailPairs(this@MainActivity)), matchWrap(top = dp(12)))
            })
        }

    private fun detailSection(title: String, rows: List<Pair<String, String>>): LinearLayout =
        LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = rounded(uiColor(R.color.ui_surface_alt), dp(12), uiColor(R.color.ui_stroke))
            setPadding(dp(14), dp(12), dp(14), dp(12))
            addView(label(title, 13f, uiColor(R.color.ui_muted), Typeface.BOLD))
            rows.forEach { (name, value) ->
                addView(LinearLayout(this@MainActivity).apply {
                    orientation = LinearLayout.VERTICAL
                    setPadding(0, dp(10), 0, 0)
                    addView(label(name, 11f, uiColor(R.color.ui_muted), Typeface.BOLD))
                    addView(label(value.ifBlank { "-" }, 15f, uiColor(R.color.ui_text)).apply {
                        setTextIsSelectable(true)
                    })
                })
            }
        }

    private fun showEditor(
        entry: VaultEntry?,
        presetCategory: String = "",
        presetTag: String = "",
    ) {
        val draft = entry?.toDraft() ?: EntryDraft(
            label = "",
            type = VaultEntryType.CREDENTIAL,
            category = presetCategory,
            tags = listOf(presetTag).filter { it.isNotBlank() },
            customFields = emptyList<CustomField>().withTemplateDefaults(store.categoryTemplate(presetCategory)),
        )
        val form = formRoot()
        val payloadFields = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        val customFieldsContainer = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        val label = input(text(R.string.label_field)).apply { setText(draft.label) }
        var selectedEntryType = draft.type
        var selectedCategory = draft.category
        val selectedTags = draft.tags.toMutableSet()
        val customFields = draft.customFields.toMutableList()
        lateinit var renderCustomFields: () -> Unit
        lateinit var categoryPicker: TextView
        categoryPicker = selectBoxText(categoryDisplayName(selectedCategory)) {
            showCategorySelectionDialog(selectedCategory) { selected ->
                selectedCategory = selected
                categoryPicker.text = categoryDisplayName(selectedCategory)
                if (entry == null) {
                    val nextFields = customFields.withTemplateDefaults(store.categoryTemplate(selectedCategory))
                    if (nextFields != customFields) {
                        customFields.clear()
                        customFields += nextFields
                        renderCustomFields()
                    }
                }
            }
        }
        val tagsSummary = TextView(this).apply {
            setTextColor(uiColor(R.color.ui_muted))
            textSize = 12f
        }
        lateinit var renderSelectedTags: () -> Unit
        lateinit var rebuildPayloadFields: (VaultEntryType) -> Unit
        val typeChipsContainer = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        fun renderTypeChips() {
            typeChipsContainer.removeAllViews()
            VaultEntryType.entries.forEach { type ->
                typeChipsContainer.addView(filterChip(type.localizedTitle(this), selectedEntryType == type) {
                    selectedEntryType = type
                    renderTypeChips()
                    rebuildPayloadFields(selectedEntryType)
                }, wrapWrap(right = dp(8)))
            }
        }
        val tagsPanel = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            isClickable = true
            isFocusable = true
            background = rounded(uiColor(R.color.ui_surface_alt), dp(12), uiColor(R.color.ui_stroke))
            setPadding(dp(12), dp(10), dp(12), dp(10))
            setOnClickListener {
                showTagSelectionDialog(
                    availableTags = store.tags(),
                    selectedTags = selectedTags,
                ) { updated ->
                    selectedTags.clear()
                    selectedTags += updated
                    renderSelectedTags()
                }
            }
        }
        renderSelectedTags = {
            tagsPanel.removeAllViews()
            tagsPanel.addView(tagsSummary)
            val chips = HorizontalScrollView(this@MainActivity).apply {
                isHorizontalScrollBarEnabled = false
                addView(LinearLayout(this@MainActivity).apply {
                    orientation = LinearLayout.HORIZONTAL
                    if (selectedTags.isEmpty()) {
                        addView(label(text(R.string.none), 13f, uiColor(R.color.ui_muted)))
                    } else {
                        selectedTags.sorted().forEachIndexed { index, tag ->
                            addView(pill(tag, selected = true), wrapWrap(right = if (index == selectedTags.size - 1) 0 else dp(8)))
                        }
                    }
                })
            }
            tagsPanel.addView(chips, matchWrap(top = dp(6)))
        }
        val categoryRow = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(label(text(R.string.category), 12f, uiColor(R.color.ui_muted), Typeface.BOLD))
            addView(categoryPicker, matchWrap(top = dp(4)))
        }
        val typeRow = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(label(text(R.string.entry_type), 12f, uiColor(R.color.ui_muted), Typeface.BOLD))
            addView(HorizontalScrollView(this@MainActivity).apply {
                isHorizontalScrollBarEnabled = false
                addView(typeChipsContainer)
            }, matchWrap(top = dp(6)))
        }
        val tagsRow = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(label(text(R.string.tags), 12f, uiColor(R.color.ui_muted), Typeface.BOLD))
            addView(tagsPanel, matchWrap(top = dp(4)))
        }
        tagsSummary.text = text(R.string.selected_tags)
        renderSelectedTags()
        val payloadInputs = mutableListOf<EditText>()
        rebuildPayloadFields = { selectedType ->
            payloadFields.removeAllViews()
            payloadInputs.clear()
            payloadFieldSpecs(selectedType, draft, this).forEach { spec ->
                payloadInputs += input(
                    hintText = spec.label,
                    secret = spec.secret,
                    singleLine = !spec.multiline,
                ).apply {
                    setText(spec.value)
                }.also { payloadFields.addView(it, matchWrap(top = dp(10))) }
            }
        }
        renderCustomFields = {
            customFieldsContainer.removeAllViews()
            customFieldsContainer.addView(sectionTitle(text(R.string.custom_fields)), matchWrap(top = dp(14)))
            if (customFields.isEmpty()) {
                customFieldsContainer.addView(label(text(R.string.no_custom_fields), 13f, uiColor(R.color.ui_muted)), matchWrap(top = dp(8)))
            }
            customFields.forEachIndexed { index, field ->
                val nameInput = input(text(R.string.custom_field_name)).apply { setText(field.name) }
                val valueInput = input(text(R.string.custom_field_value)).apply { setText(field.value) }
                customFieldsContainer.addView(LinearLayout(this).apply {
                    orientation = LinearLayout.VERTICAL
                    background = rounded(uiColor(R.color.ui_surface_alt), dp(12), uiColor(R.color.ui_stroke))
                    setPadding(dp(12), dp(12), dp(12), dp(12))
                    addView(nameInput, matchWrap())
                    addView(valueInput, matchWrap(top = dp(8)))
                    addView(actionButton(text(R.string.delete), primary = false, compact = true) {
                        customFields.removeAt(index)
                        renderCustomFields()
                    }, wrapWrap(top = dp(8)))
                    nameInput.addTextChangedListener(SimpleTextWatcher { value ->
                        customFields[index] = customFields[index].copy(name = value)
                    })
                    valueInput.addTextChangedListener(SimpleTextWatcher { value ->
                        customFields[index] = customFields[index].copy(value = value)
                    })
                }, matchWrap(top = dp(8)))
            }
            customFieldsContainer.addView(actionButton(text(R.string.add_custom_field), primary = false) {
                customFields += CustomField()
                renderCustomFields()
            }, matchWrap(top = dp(10)))
        }
        form.addView(formTitle(if (entry == null) text(R.string.new_entry) else text(R.string.edit_entry)))
        form.addView(label, matchWrap(top = dp(12)))
        form.addView(typeRow, matchWrap(top = dp(10)))
        form.addView(categoryRow, matchWrap(top = dp(10)))
        form.addView(tagsRow, matchWrap(top = dp(10)))
        form.addView(payloadFields)
        form.addView(customFieldsContainer)
        renderTypeChips()
        rebuildPayloadFields(selectedEntryType)
        renderCustomFields()
        val dialog = AlertDialog.Builder(this)
            .setView(ScrollView(this).apply { addView(form) })
            .setPositiveButton(text(R.string.save), null)
            .setNegativeButton(text(R.string.cancel), null)
            .create()
        dialog.setOnShowListener {
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
                if (label.text.toString().isBlank()) {
                    toast(text(R.string.label_required))
                    return@setOnClickListener
                }
                val savedDraft = EntryDraft(
                    label = label.text.toString(),
                    type = selectedEntryType,
                    category = selectedCategory,
                    tags = selectedTags.sorted(),
                    customFields = customFields
                        .map { it.copy(name = it.name.trim(), value = it.value.trim()) }
                        .filter { it.name.isNotBlank() || it.value.isNotBlank() },
                    credential = credentialPayload(payloadInputs),
                    server = serverPayload(payloadInputs),
                    service = servicePayload(payloadInputs),
                )
                val savedEntry = store.upsert(savedDraft, editingId = entry?.id)
                selectedEntry = savedEntry
                dialog.dismiss()
                showHome()
            }
        }
        dialog.show()
    }

    private fun showExportDialog() {
        val form = formRoot()
        form.addView(formTitle(text(R.string.export)))
        form.addView(label(text(R.string.export_picker_hint), 13f, uiColor(R.color.ui_muted)), matchWrap(top = dp(6)))
        form.addView(actionButton(text(R.string.save_full_vault_json), primary = true) {
            store.exportSnapshotJson()?.let { json ->
                createJsonDocument("vault-export-${exportTimestamp()}.json", json)
            } ?: toast(store.statusMessage ?: text(R.string.export_failed))
        }, matchWrap(top = dp(16)))
        selectedEntry?.let { entry ->
            form.addView(actionButton(text(R.string.save_selected_entry_json), primary = false) {
                showEntryExportFieldDialog(entry)
            }, matchWrap(top = dp(10)))
        }
        form.addView(actionButton(text(R.string.save_category_json), primary = false) {
            showCategoryExportDialog()
        }, matchWrap(top = dp(10)))
        form.addView(actionButton(text(R.string.create_app_private_backup), primary = false) {
            runBackup()
        }, matchWrap(top = dp(10)))
        AlertDialog.Builder(this)
            .setView(form)
            .setNegativeButton(text(R.string.close), null)
            .show()
    }

    private fun showEntryExportFieldDialog(entry: VaultEntry) {
        val fields = entry.exportFields(this)
        val selected = mutableSetOf<String>()
        val form = formRoot()
        form.addView(formTitle(text(R.string.choose_export_fields)))
        form.addView(label(text(R.string.choose_export_fields_hint), 13f, uiColor(R.color.ui_muted)), matchWrap(top = dp(8)))
        fields.forEach { field ->
            val checkBox = CheckBox(this).apply {
                text = field.title
                isChecked = false
                setTextColor(uiColor(R.color.ui_text))
                setOnCheckedChangeListener { _, checked ->
                    if (checked) {
                        selected += field.id
                    } else {
                        selected -= field.id
                    }
                }
            }
            form.addView(checkBox, matchWrap(top = dp(6)))
        }
        val dialog = AlertDialog.Builder(this)
            .setView(ScrollView(this).apply { addView(form) })
            .setPositiveButton(text(R.string.export_selected), null)
            .setNeutralButton(text(R.string.export_all), null)
            .setNegativeButton(text(R.string.cancel), null)
            .create()
        dialog.setOnShowListener {
            dialog.getButton(AlertDialog.BUTTON_NEUTRAL).setOnClickListener {
                exportEntryJson(entry, null)
                dialog.dismiss()
            }
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
                if (selected.isEmpty()) {
                    toast(text(R.string.choose_at_least_one_field))
                    return@setOnClickListener
                }
                exportEntryJson(entry, selected.toSet())
                dialog.dismiss()
            }
        }
        dialog.show()
    }

    private fun exportEntryJson(entry: VaultEntry, selectedFieldIds: Set<String>?) {
        store.exportEntryJson(entry, selectedFieldIds)?.let { json ->
            createJsonDocument("entry-export-${safeExportName(entry.label)}-${exportTimestamp()}.json", json)
        } ?: toast(store.statusMessage ?: text(R.string.export_failed))
    }

    private fun showImportCenterDialog() {
        val form = formRoot()
        form.addView(formTitle(text(R.string.import_label)))
        form.addView(label(text(R.string.import_picker_hint), 13f, uiColor(R.color.ui_muted)), matchWrap(top = dp(6)))
        form.addView(actionButton(text(R.string.choose_full_vault_json), primary = true) {
            showImportDialog()
        }, matchWrap(top = dp(16)))
        form.addView(actionButton(text(R.string.choose_item_category_json), primary = false) {
            showScopedImportDialog()
        }, matchWrap(top = dp(10)))
        AlertDialog.Builder(this)
            .setView(form)
            .setNegativeButton(text(R.string.close), null)
            .show()
    }

    private fun showTaxonomyInputDialog(
        kind: TaxonomyKind,
        onSaved: ((String) -> Unit)? = null,
        returnToHomeAfterSave: Boolean = true,
    ) {
        val form = formRoot()
        val title = when (kind) {
            TaxonomyKind.CATEGORY -> text(R.string.create_category)
            TaxonomyKind.TAG -> text(R.string.create_tag)
        }
        val description = when (kind) {
            TaxonomyKind.CATEGORY -> text(R.string.create_category_hint)
            TaxonomyKind.TAG -> text(R.string.create_tag_hint)
        }
        val field = input(when (kind) {
            TaxonomyKind.CATEGORY -> text(R.string.category)
            TaxonomyKind.TAG -> text(R.string.tag)
        })
        var selectedPreset: CategoryTypePreset? = null
        val presetStrip = if (kind == TaxonomyKind.CATEGORY) {
            LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                addView(label(text(R.string.category_type_templates), 12f, uiColor(R.color.ui_muted), Typeface.BOLD))
                val chipsContainer = LinearLayout(this@MainActivity).apply {
                    orientation = LinearLayout.HORIZONTAL
                }
                fun renderPresetChips() {
                    chipsContainer.removeAllViews()
                    CategoryTypePreset.entries.forEach { preset ->
                        chipsContainer.addView(filterChip(preset.title, selectedPreset == preset) {
                            selectedPreset = if (selectedPreset == preset) null else preset
                            renderPresetChips()
                        }, wrapWrap(right = dp(8)))
                    }
                }
                addView(HorizontalScrollView(this@MainActivity).apply {
                    isHorizontalScrollBarEnabled = false
                    addView(chipsContainer)
                }, matchWrap(top = dp(6)))
                addView(label(text(R.string.category_type_templates_hint), 12f, uiColor(R.color.ui_muted)), matchWrap(top = dp(6)))
                renderPresetChips()
            }
        } else {
            null
        }
        form.addView(formTitle(title))
        form.addView(label(description, 13f, uiColor(R.color.ui_muted)), matchWrap(top = dp(8)))
        presetStrip?.let { form.addView(it, matchWrap(top = dp(12))) }
        form.addView(field, matchWrap(top = dp(14)))
        val dialog = AlertDialog.Builder(this)
            .setView(form)
            .setPositiveButton(text(R.string.save), null)
            .setNegativeButton(text(R.string.cancel), null)
            .create()
        dialog.setOnShowListener {
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
                val value = field.text.toString().trim()
                if (value.isBlank()) {
                    toast(text(R.string.value_required))
                    return@setOnClickListener
                }
                val saved = when (kind) {
                    TaxonomyKind.CATEGORY -> selectedPreset?.let { preset ->
                        store.addCategory(value, CategoryTemplate.fieldsForPreset(preset))
                    } ?: store.addCategory(value)
                    TaxonomyKind.TAG -> store.addTag(value)
                }
                if (!saved) {
                    toast(store.statusMessage ?: text(R.string.operation_failed))
                    return@setOnClickListener
                }
                dialog.dismiss()
                onSaved?.invoke(value)
                if (returnToHomeAfterSave) {
                    showHome()
                }
                toast(store.statusMessage ?: text(R.string.saved))
            }
        }
        dialog.show()
    }

    private fun showSyncCenter() {
        val form = formRoot()
        val settings = store.syncSettings
        var dialog: AlertDialog? = null
        form.addView(formTitle(text(R.string.sync_center)))
        form.addView(label(text(R.string.provider_value, settings.providerType.localizedTitle(this)), 14f, uiColor(R.color.ui_text), Typeface.BOLD), matchWrap(top = dp(12)))
        form.addView(label(text(R.string.status_value, store.syncStatus), 13f, uiColor(R.color.ui_muted)), matchWrap(top = dp(4)))
        form.addView(label(text(R.string.revision_value, settings.lastSyncRevision), 13f, uiColor(R.color.ui_muted)), matchWrap(top = dp(4)))
        form.addView(label(text(R.string.last_sync_value, settings.lastSyncAt?.let(::formatInstant) ?: text(R.string.never)), 13f, uiColor(R.color.ui_muted)), matchWrap(top = dp(4)))
        settings.lastSyncMessage?.takeIf { it.isNotBlank() }?.let { message ->
            form.addView(detailSection(text(R.string.last_result), listOf(text(R.string.message) to message)), matchWrap(top = dp(14)))
        }
        form.addView(actionButton(text(R.string.run_sync_now), primary = true) {
            dialog?.dismiss()
            runSync()
        }, matchWrap(top = dp(16)))
        form.addView(actionButton(text(R.string.edit_sync_settings), primary = false) {
            dialog?.dismiss()
            showSettings()
        }, matchWrap(top = dp(10)))
        form.addView(sectionTitle(text(R.string.recent_logs)), matchWrap(top = dp(18)))
        if (settings.logs.isEmpty()) {
            form.addView(label(text(R.string.no_sync_logs), 13f, uiColor(R.color.ui_muted)), matchWrap(top = dp(8)))
        } else {
            settings.logs.take(8).forEach { log ->
                form.addView(syncLogRow(log), matchWrap(top = dp(8)))
            }
        }
        dialog = AlertDialog.Builder(this)
            .setView(ScrollView(this).apply { addView(form) })
            .setNegativeButton(text(R.string.close), null)
            .show()
    }

    private fun syncLogRow(log: SyncLogEntry): LinearLayout =
        LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = rounded(
                if (log.level.equals("error", ignoreCase = true)) uiColor(R.color.ui_error_surface) else uiColor(R.color.ui_surface_alt),
                dp(12),
                if (log.level.equals("error", ignoreCase = true)) uiColor(R.color.ui_error_stroke) else uiColor(R.color.ui_stroke)
            )
            setPadding(dp(12), dp(10), dp(12), dp(10))
            addView(LinearLayout(this@MainActivity).apply {
                gravity = Gravity.CENTER_VERTICAL
                addView(label(log.level.uppercase(), 11f, if (log.level.equals("error", ignoreCase = true)) uiColor(R.color.ui_error) else uiColor(R.color.ui_accent), Typeface.BOLD), LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
                addView(label(formatInstant(log.timestamp), 11f, uiColor(R.color.ui_muted)))
            })
            addView(label(log.message.ifBlank { "-" }, 13f, uiColor(R.color.ui_text)).apply {
                setPadding(0, dp(6), 0, 0)
            })
        }

    private fun showBackupCenter(anchor: View? = null) {
        val form = formRoot()
        val backups = store.listBackups()
        var popup: PopupWindow? = null
        form.addView(formTitle(text(R.string.backups)))
        form.addView(label(text(R.string.backups_hint), 13f, uiColor(R.color.ui_muted)), matchWrap(top = dp(6)))
        form.addView(actionButton(text(R.string.create_backup_now), primary = true) {
            popup?.dismiss()
            runBackup()
        }, matchWrap(top = dp(16)))
        form.addView(sectionTitle(text(R.string.available_backups)), matchWrap(top = dp(18)))
        if (backups.isEmpty()) {
            form.addView(label(text(R.string.no_backups), 13f, uiColor(R.color.ui_muted)), matchWrap(top = dp(8)))
        } else {
            backups.forEach { backup ->
                form.addView(backupRow(backup), matchWrap(top = dp(8)))
            }
        }
        popup = showAnchoredPopup(anchor, ScrollView(this).apply { addView(form) }, maxHeight = dp(560))
    }

    private fun backupRow(backup: BackupInfo): LinearLayout =
        LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = rounded(uiColor(R.color.ui_surface_alt), dp(12), uiColor(R.color.ui_stroke))
            setPadding(dp(12), dp(10), dp(12), dp(10))
            addView(label(backup.fileName, 14f, uiColor(R.color.ui_text), Typeface.BOLD))
            addView(label("${formatBytes(backup.sizeBytes)}  -  ${formatInstant(backup.modifiedAt)}", 12f, uiColor(R.color.ui_muted)).apply {
                setPadding(0, dp(4), 0, dp(10))
            })
            addView(actionButton(text(R.string.restore_this_backup), primary = false) {
                confirmRestoreBackup(backup)
            }, wrapWrap())
        }

    private fun confirmRestoreBackup(backup: BackupInfo) {
        val content = formRoot()
        content.addView(formTitle(text(R.string.restore_backup)))
        content.addView(label(text(R.string.restore_backup_confirm, backup.fileName), 13f, uiColor(R.color.ui_muted)), matchWrap(top = dp(8)))
        AlertDialog.Builder(this)
            .setView(content)
            .setPositiveButton(text(R.string.restore)) { _, _ ->
                store.restoreBackup(backup.fileName)
                selectedEntry = null
                showHome()
                toast(store.statusMessage ?: text(R.string.restore_complete))
            }
            .setNegativeButton(text(R.string.cancel), null)
            .show()
    }

    private fun showImportDialog() {
        val form = formRoot()
        form.addView(formTitle(text(R.string.import_full_vault)))
        form.addView(label(
            text(R.string.import_full_vault_warning),
            13f,
            uiColor(R.color.ui_muted)
        ), matchWrap(top = dp(8)))
        AlertDialog.Builder(this)
            .setView(form)
            .setPositiveButton(text(R.string.choose_file)) { _, _ ->
                openJsonDocument(PendingImportKind.SNAPSHOT)
            }
            .setNegativeButton(text(R.string.cancel), null)
            .show()
    }

    private fun showRestoreBackupDialog() {
        showBackupCenter()
    }

    private fun showCategoryExportDialog() {
        val form = formRoot()
        val categories = store.categories()
        val category = if (categories.isNotEmpty()) {
            Spinner(this).apply {
                adapter = ArrayAdapter(
                    this@MainActivity,
                    android.R.layout.simple_spinner_dropdown_item,
                    categories,
                )
            }
        } else {
            null
        }
        val manualCategory = input(text(R.string.category)).apply {
            visibility = if (categories.isEmpty()) View.VISIBLE else View.GONE
        }
        form.addView(formTitle(text(R.string.export_category)))
        if (category != null) {
            form.addView(category, matchWrap(top = dp(14)))
        }
        form.addView(manualCategory, matchWrap(top = dp(14)))
        AlertDialog.Builder(this)
            .setView(form)
            .setPositiveButton(text(R.string.save)) { _, _ ->
                val value = if (category != null) {
                    categories[category.selectedItemPosition]
                } else {
                    manualCategory.text.toString()
                }
                store.exportCategoryJson(value)?.let { json ->
                    createJsonDocument("category-export-${safeExportName(value)}-${exportTimestamp()}.json", json)
                } ?: toast(store.statusMessage ?: text(R.string.export_failed))
            }
            .setNegativeButton(text(R.string.cancel), null)
            .show()
    }

    private fun showScopedImportDialog() {
        val form = formRoot()
        val strategy = Spinner(this).apply {
            adapter = ArrayAdapter(
                this@MainActivity,
                android.R.layout.simple_spinner_dropdown_item,
                ImportConflictStrategy.entries.map { it.localizedTitle(this@MainActivity) },
            )
            setSelection(ImportConflictStrategy.entries.indexOf(ImportConflictStrategy.KEEP_COPY))
        }
        form.addView(formTitle(text(R.string.import_item_or_category)))
        form.addView(label(
            text(R.string.import_scoped_hint),
            13f,
            uiColor(R.color.ui_muted)
        ), matchWrap(top = dp(8)))
        form.addView(label(text(R.string.conflict_strategy), 12f, uiColor(R.color.ui_muted), Typeface.BOLD), matchWrap(top = dp(14)))
        form.addView(strategy, matchWrap(top = dp(4)))
        AlertDialog.Builder(this)
            .setView(form)
            .setPositiveButton(text(R.string.choose_file)) { _, _ ->
                val selectedStrategy = ImportConflictStrategy.entries[strategy.selectedItemPosition]
                openJsonDocument(PendingImportKind.SCOPED, selectedStrategy)
            }
            .setNegativeButton(text(R.string.cancel), null)
            .show()
    }

    private fun showSettings() {
        val form = formRoot()
        val settings = store.syncSettings
        val requireTotp = CheckBox(this).apply {
            text = text(R.string.require_totp_on_unlock)
            isChecked = store.requireTotp
            setTextColor(uiColor(R.color.ui_text))
        }
        val secret = input(text(R.string.totp_shared_secret), secret = true).apply { setText(store.totpSecret) }
        val biometricUnlock = CheckBox(this).apply {
            text = text(R.string.enable_biometric_unlock)
            isChecked = isBiometricUnlockEnabled() && biometricCredentialStore.hasSavedCredential()
            isEnabled = biometricCredentialStore.canAuthenticate()
            setTextColor(uiColor(R.color.ui_text))
        }
        val biometricPassword = input(text(R.string.master_password), secret = true).apply {
            visibility = if (biometricUnlock.isChecked || !biometricCredentialStore.canAuthenticate()) View.GONE else View.VISIBLE
        }
        val idleAutoLockMinutes = input(text(R.string.idle_auto_lock_minutes), inputType = InputType.TYPE_CLASS_NUMBER).apply {
            setText(getIdleAutoLockMinutes().toString())
        }
        val provider = Spinner(this).apply {
            adapter = ArrayAdapter(
                this@MainActivity,
                android.R.layout.simple_spinner_dropdown_item,
                SyncProviderType.entries.map { it.localizedTitle(this@MainActivity) },
            )
            setSelection(SyncProviderType.entries.indexOf(settings.providerType))
        }
        val webdavUrl = input(text(R.string.webdav_url)).apply { setText(settings.webdavUrl) }
        val webdavPath = input(text(R.string.webdav_path)).apply { setText(settings.webdavPath) }
        val webdavUsername = input(text(R.string.webdav_username)).apply { setText(settings.webdavUsername) }
        val webdavPassword = input(text(R.string.webdav_password), secret = true).apply { setText(settings.webdavPassword) }
        val webdavSection = sectionTitle(text(R.string.webdav_settings))
        val presignedDownloadUrl = input(text(R.string.presigned_download_url)).apply { setText(settings.presignedDownloadUrl) }
        val presignedUploadUrl = input(text(R.string.presigned_upload_url), secret = true).apply { setText(settings.presignedUploadUrl) }
        val presignedSection = sectionTitle(text(R.string.presigned_url_settings))
        val objectStorageAccessKeyId = input(text(R.string.object_storage_access_key_id), secret = true).apply {
            setText(settings.objectStorageAccessKeyId)
        }
        val objectStorageSecretAccessKey = input(text(R.string.object_storage_secret_access_key), secret = true).apply {
            setText(settings.objectStorageSecretAccessKey)
        }
        val objectStorageBucket = input(text(R.string.object_storage_bucket)).apply { setText(settings.objectStorageBucket) }
        val objectStorageEndpoint = input(text(R.string.object_storage_endpoint)).apply { setText(settings.objectStorageEndpoint) }
        val objectStorageAppId = input(text(R.string.object_storage_app_id)).apply { setText(settings.objectStorageAppId) }
        val objectStorageCustomUrl = input(text(R.string.object_storage_custom_url)).apply { setText(settings.objectStorageCustomUrl) }
        val objectStorageObjectKey = input(text(R.string.object_storage_object_key)).apply { setText(settings.objectStorageObjectKey) }
        val objectStorageSection = sectionTitle(text(R.string.object_storage_settings))
        val objectStorageHint = label(text(R.string.object_storage_settings_hint), 12f, uiColor(R.color.ui_muted))
        val autoSync = CheckBox(this).apply {
            text = text(R.string.auto_sync)
            isChecked = settings.autoSyncEnabled
            setTextColor(uiColor(R.color.ui_text))
        }
        val autoSyncInterval = input(text(R.string.auto_sync_interval_value), inputType = InputType.TYPE_CLASS_NUMBER).apply {
            setText(settings.autoSyncIntervalValue.toString())
        }
        val autoSyncIntervalUnit = Spinner(this).apply {
            adapter = ArrayAdapter(
                this@MainActivity,
                android.R.layout.simple_spinner_dropdown_item,
                SyncIntervalUnit.entries.map { it.localizedTitle(this@MainActivity) },
            )
            setSelection(SyncIntervalUnit.entries.indexOf(settings.autoSyncIntervalUnit))
        }
        val autoSyncOnUnlock = CheckBox(this).apply {
            text = text(R.string.sync_on_unlock)
            isChecked = settings.autoSyncOnUnlock
            setTextColor(uiColor(R.color.ui_text))
        }
        val conflictStrategy = Spinner(this).apply {
            adapter = ArrayAdapter(
                this@MainActivity,
                android.R.layout.simple_spinner_dropdown_item,
                SyncSettingsConflictStrategy.entries.map { it.localizedTitle(this@MainActivity) },
            )
            setSelection(SyncSettingsConflictStrategy.entries.indexOf(settings.conflictStrategy))
        }
        val syncMasterKey = CheckBox(this).apply {
            text = text(R.string.sync_master_key_metadata)
            isChecked = settings.syncMasterKey
            setTextColor(uiColor(R.color.ui_text))
        }
        val webdavFields = listOf(webdavSection, webdavUrl, webdavPath, webdavUsername, webdavPassword)
        val presignedFields = listOf(presignedSection, presignedDownloadUrl, presignedUploadUrl)
        val objectStorageFields = listOf(
            objectStorageSection,
            objectStorageHint,
            objectStorageAccessKeyId,
            objectStorageSecretAccessKey,
            objectStorageBucket,
            objectStorageEndpoint,
            objectStorageAppId,
            objectStorageCustomUrl,
            objectStorageObjectKey,
        )
        fun updateProviderFieldVisibility() {
            val selectedProvider = SyncProviderType.entries[provider.selectedItemPosition]
            val showWebdav = selectedProvider == SyncProviderType.WEBDAV || selectedProvider == SyncProviderType.NAS_WEBDAV
            val showPresigned = selectedProvider == SyncProviderType.S3_PRESIGNED
            val showObjectStorage = selectedProvider == SyncProviderType.TENCENT_COS || selectedProvider == SyncProviderType.ALIYUN_OSS
            webdavFields.forEach { it.visibility = if (showWebdav) View.VISIBLE else View.GONE }
            presignedFields.forEach { it.visibility = if (showPresigned) View.VISIBLE else View.GONE }
            objectStorageFields.forEach { it.visibility = if (showObjectStorage) View.VISIBLE else View.GONE }
            objectStorageAppId.visibility = if (selectedProvider == SyncProviderType.TENCENT_COS) View.VISIBLE else View.GONE
        }
        provider.onItemSelectedListener = object : android.widget.AdapterView.OnItemSelectedListener {
            override fun onItemSelected(
                parent: android.widget.AdapterView<*>?,
                view: View?,
                position: Int,
                id: Long,
            ) {
                updateProviderFieldVisibility()
            }

            override fun onNothingSelected(parent: android.widget.AdapterView<*>?) = Unit
        }
        biometricUnlock.setOnCheckedChangeListener { _, checked ->
            biometricPassword.visibility = if (checked && !biometricCredentialStore.hasSavedCredential()) View.VISIBLE else View.GONE
        }

        form.addView(formTitle(text(R.string.settings)))
        form.addView(sectionTitle(text(R.string.security)), matchWrap(top = dp(12)))
        form.addView(requireTotp, matchWrap(top = dp(4)))
        form.addView(secret, matchWrap(top = dp(8)))
        form.addView(biometricUnlock, matchWrap(top = dp(10)))
        if (!biometricCredentialStore.canAuthenticate()) {
            form.addView(label(text(R.string.biometric_unavailable), 13f, uiColor(R.color.ui_muted)), matchWrap(top = dp(4)))
        }
        form.addView(biometricPassword, matchWrap(top = dp(8)))
        form.addView(label(text(R.string.idle_auto_lock), 12f, uiColor(R.color.ui_muted), Typeface.BOLD), matchWrap(top = dp(12)))
        form.addView(idleAutoLockMinutes, matchWrap(top = dp(8)))
        form.addView(label(text(R.string.idle_auto_lock_hint), 12f, uiColor(R.color.ui_muted)), matchWrap(top = dp(4)))
        form.addView(sectionTitle(text(R.string.sync)), matchWrap(top = dp(18)))
        form.addView(provider, matchWrap(top = dp(8)))
        form.addView(webdavSection, matchWrap(top = dp(12)))
        form.addView(webdavUrl, matchWrap(top = dp(8)))
        form.addView(webdavPath, matchWrap(top = dp(8)))
        form.addView(webdavUsername, matchWrap(top = dp(8)))
        form.addView(webdavPassword, matchWrap(top = dp(8)))
        form.addView(presignedSection, matchWrap(top = dp(12)))
        form.addView(presignedDownloadUrl, matchWrap(top = dp(8)))
        form.addView(presignedUploadUrl, matchWrap(top = dp(8)))
        form.addView(objectStorageSection, matchWrap(top = dp(12)))
        form.addView(objectStorageHint, matchWrap(top = dp(4)))
        form.addView(objectStorageAccessKeyId, matchWrap(top = dp(8)))
        form.addView(objectStorageSecretAccessKey, matchWrap(top = dp(8)))
        form.addView(objectStorageBucket, matchWrap(top = dp(8)))
        form.addView(objectStorageEndpoint, matchWrap(top = dp(8)))
        form.addView(objectStorageAppId, matchWrap(top = dp(8)))
        form.addView(objectStorageCustomUrl, matchWrap(top = dp(8)))
        form.addView(objectStorageObjectKey, matchWrap(top = dp(8)))
        form.addView(autoSync, matchWrap(top = dp(10)))
        form.addView(label(text(R.string.auto_sync_interval), 12f, uiColor(R.color.ui_muted), Typeface.BOLD), matchWrap(top = dp(8)))
        form.addView(autoSyncInterval, matchWrap(top = dp(8)))
        form.addView(autoSyncIntervalUnit, matchWrap(top = dp(6)))
        form.addView(autoSyncOnUnlock, matchWrap(top = dp(8)))
        form.addView(label(text(R.string.conflict_strategy), 12f, uiColor(R.color.ui_muted), Typeface.BOLD), matchWrap(top = dp(12)))
        form.addView(conflictStrategy, matchWrap(top = dp(4)))
        form.addView(syncMasterKey, matchWrap(top = dp(8)))
        form.addView(sectionTitle(text(R.string.device)), matchWrap(top = dp(18)))
        form.addView(label(text(R.string.device_value, settings.deviceId), 13f, uiColor(R.color.ui_muted)), matchWrap(top = dp(4)))
        form.addView(label(text(R.string.revision_value, settings.lastSyncRevision), 13f, uiColor(R.color.ui_muted)), matchWrap(top = dp(2)))
        updateProviderFieldVisibility()

        val dialog = AlertDialog.Builder(this)
            .setView(ScrollView(this).apply { addView(form) })
            .setPositiveButton(text(R.string.save), null)
            .setNegativeButton(text(R.string.cancel), null)
            .create()
        dialog.setOnShowListener {
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
                if (biometricUnlock.isChecked && !biometricCredentialStore.hasSavedCredential()) {
                    val password = biometricPassword.text.toString()
                    if (!store.verifyMasterPassword(password)) {
                        toast(store.statusMessage ?: text(R.string.operation_failed))
                        return@setOnClickListener
                    }
                    enableBiometricUnlock(password)
                } else if (biometricUnlock.isChecked) {
                    setBiometricUnlockEnabled(true)
                } else {
                    biometricCredentialStore.clear()
                    setBiometricUnlockEnabled(false)
                    biometricFallbackRequired = false
                    biometricFailureCount = 0
                }
                store.setTotpSecret(secret.text.toString())
                store.setRequireTotp(requireTotp.isChecked)
                setIdleAutoLockMinutes(idleAutoLockMinutes.text.toString().toIntOrNull()?.coerceIn(0, 1440) ?: 0)
                val selectedIntervalUnit = SyncIntervalUnit.entries[autoSyncIntervalUnit.selectedItemPosition]
                val selectedIntervalValue = autoSyncInterval.text.toString()
                    .toIntOrNull()
                    ?.coerceIn(1, 1440)
                    ?: store.syncSettings.autoSyncIntervalValue
                val selectedProviderType = SyncProviderType.entries[provider.selectedItemPosition]
                if (
                    (selectedProviderType == SyncProviderType.TENCENT_COS || selectedProviderType == SyncProviderType.ALIYUN_OSS) &&
                    (objectStorageAccessKeyId.text.toString().isBlank() ||
                        objectStorageSecretAccessKey.text.toString().isBlank() ||
                        objectStorageBucket.text.toString().isBlank())
                ) {
                    toast(text(R.string.object_storage_required_fields))
                    return@setOnClickListener
                }
                store.updateSyncSettings(
                    store.syncSettings.copy(
                        providerType = selectedProviderType,
                        webdavUrl = webdavUrl.text.toString(),
                        webdavPath = webdavPath.text.toString(),
                        webdavUsername = webdavUsername.text.toString(),
                        webdavPassword = webdavPassword.text.toString(),
                        presignedDownloadUrl = presignedDownloadUrl.text.toString(),
                        presignedUploadUrl = presignedUploadUrl.text.toString(),
                        objectStorageAccessKeyId = objectStorageAccessKeyId.text.toString(),
                        objectStorageSecretAccessKey = objectStorageSecretAccessKey.text.toString(),
                        objectStorageBucket = objectStorageBucket.text.toString(),
                        objectStorageEndpoint = objectStorageEndpoint.text.toString(),
                        objectStorageAppId = objectStorageAppId.text.toString(),
                        objectStorageCustomUrl = objectStorageCustomUrl.text.toString(),
                        objectStorageObjectKey = objectStorageObjectKey.text.toString().ifBlank { "vault.sync.json" },
                        autoSyncEnabled = autoSync.isChecked,
                        autoSyncIntervalMinutes = selectedIntervalValue.toIntervalMinutes(selectedIntervalUnit),
                        autoSyncIntervalValue = selectedIntervalValue,
                        autoSyncIntervalUnit = selectedIntervalUnit,
                        autoSyncOnUnlock = autoSyncOnUnlock.isChecked,
                        conflictStrategy = SyncSettingsConflictStrategy.entries[conflictStrategy.selectedItemPosition],
                        syncMasterKey = syncMasterKey.isChecked,
                    )
                )
                dialog.dismiss()
                showHome()
                toast(store.statusMessage ?: text(R.string.settings_saved))
            }
        }
        dialog.show()
    }

    private fun runSync() {
        startSync(showToast = true)
    }

    private fun startSync(showToast: Boolean) {
        if (activeSyncJob?.isActive == true) {
            if (showToast) {
                toast(store.syncStatus)
            }
            return
        }
        activeSyncJob = layoutScope.launch {
            val message = withContext(Dispatchers.IO) {
                store.syncNow()
                store.statusMessage ?: store.syncStatus
            }
            if (store.isUnlocked) {
                showHome(preserveEntryScroll = true)
            } else {
                showUnlock()
            }
            if (showToast) {
                toast(message)
            }
        }
    }

    private fun runBackup() {
        store.runBackup()
        showHome()
        toast(store.backupStatus)
    }

    private fun createJsonDocument(fileName: String, json: String) {
        pendingExportJson = json
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "application/json"
            putExtra(Intent.EXTRA_TITLE, fileName)
        }
        runCatching {
            startActivityForResult(intent, RequestCodeCreateDocument)
        }.onFailure {
            pendingExportJson = null
            toast(text(R.string.no_file_manager_save))
        }
    }

    private fun openJsonDocument(
        kind: PendingImportKind,
        strategy: ImportConflictStrategy = ImportConflictStrategy.KEEP_COPY,
    ) {
        pendingImportKind = kind
        pendingImportStrategy = strategy
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "application/json"
        }
        runCatching {
            startActivityForResult(intent, RequestCodeOpenDocument)
        }.onFailure {
            pendingImportKind = null
            toast(text(R.string.no_file_manager_choose))
        }
    }

    private fun writePendingExport(uri: Uri) {
        val json = pendingExportJson ?: return
        runCatching {
            contentResolver.openOutputStream(uri, "wt")?.use { output ->
                output.write(json.toByteArray(Charsets.UTF_8))
            } ?: error(text(R.string.could_not_open_selected_file))
            statusRefresh(text(R.string.export_saved))
        }.onFailure {
            toast(it.message ?: text(R.string.export_failed))
        }
        pendingExportJson = null
    }

    private fun readSelectedImport(uri: Uri) {
        val kind = pendingImportKind ?: return
        val strategy = pendingImportStrategy
        pendingImportKind = null
        pendingImportStrategy = ImportConflictStrategy.KEEP_COPY
        toast(text(R.string.import_started))
        layoutScope.launch {
            val result = withContext(Dispatchers.IO) {
                runCatching {
                    val raw = contentResolver.openInputStream(uri)?.use { input ->
                        input.readBytes().toString(Charsets.UTF_8)
                    } ?: error(text(R.string.could_not_open_selected_file))
                    val imported = when (kind) {
                        PendingImportKind.SNAPSHOT -> store.importSnapshotJson(raw)
                        PendingImportKind.SCOPED -> store.importScopedExportJson(raw, strategy)
                    }
                    ImportResultMessage(
                        success = imported,
                        message = store.statusMessage ?: text(
                            if (imported) R.string.import_complete else R.string.import_failed
                        ),
                    )
                }.getOrElse {
                    ImportResultMessage(false, it.message ?: text(R.string.import_failed))
                }
            }
            if (result.success) {
                resetVaultViewState()
                showHome()
            }
            showImportResult(result.message)
        }
    }

    private fun statusRefresh(message: String) {
        showHome()
        toast(message)
    }

    private fun lockVaultAndShowUnlock(idleTimeout: Boolean = false) {
        currentBiometricPrompt?.cancelAuthentication()
        currentBiometricPrompt = null
        store.lock()
        selectedEntry = null
        lastAutoSyncUnlockState = false
        biometricPromptInFlight = false
        biometricFailureCount = 0
        biometricFallbackRequired = false
        showUnlock()
        if (idleTimeout) {
            toast(text(R.string.idle_auto_locked))
        }
    }

    private fun markUserActivity() {
        lastUserActivityAt = System.currentTimeMillis()
    }

    private fun checkIdleAutoLock() {
        val minutes = getIdleAutoLockMinutes()
        if (!store.isUnlocked || minutes <= 0) return
        val elapsed = System.currentTimeMillis() - lastUserActivityAt
        if (elapsed >= minutes * 60_000L) {
            lockVaultAndShowUnlock(idleTimeout = true)
        }
    }

    private fun syncOnUnlockIfNeeded() {
        if (!store.isUnlocked) {
            lastAutoSyncUnlockState = false
            return
        }
        val policy = autoSyncPolicy()
        if (!policy.shouldSyncOnUnlock(hasTriggeredForCurrentUnlock = lastAutoSyncUnlockState)) {
            return
        }
        lastAutoSyncUnlockState = true
        lastAutoSyncAttemptAt = Instant.now()
        startSync(showToast = false)
    }

    private fun runAutoSyncIfNeeded() {
        if (!store.isUnlocked) {
            lastAutoSyncUnlockState = false
            return
        }
        val now = Instant.now()
        if (!autoSyncPolicy().shouldRunIntervalSync(now)) {
            return
        }
        lastAutoSyncAttemptAt = now
        startSync(showToast = false)
    }

    private fun autoSyncPolicy(): AutoSyncSchedulePolicy =
        AutoSyncSchedulePolicy(
            settings = store.syncSettings,
            isUnlocked = store.isUnlocked,
            syncStatus = store.syncStatus,
            lastAutoSyncAttemptAt = lastAutoSyncAttemptAt,
        )

    private fun isBiometricUnlockEnabled(): Boolean =
        appPreferences.getBoolean(PrefBiometricUnlockEnabled, false)

    private fun setBiometricUnlockEnabled(enabled: Boolean) {
        appPreferences.edit().putBoolean(PrefBiometricUnlockEnabled, enabled).apply()
    }

    private fun getIdleAutoLockMinutes(): Int =
        appPreferences.getInt(PrefIdleAutoLockMinutes, 0)

    private fun setIdleAutoLockMinutes(minutes: Int) {
        appPreferences.edit().putInt(PrefIdleAutoLockMinutes, minutes.coerceIn(0, 1440)).apply()
        markUserActivity()
    }

    private fun showImportResult(message: String) {
        if (isFinishing) return
        AlertDialog.Builder(this)
            .setTitle(text(R.string.import_label))
            .setMessage(message)
            .setPositiveButton(text(R.string.close), null)
            .show()
    }

    private fun resetVaultViewState() {
        selectedEntry = null
        selectedType = null
        selectedCategory = null
        selectedTag = null
        searchQuery = ""
    }

    private fun captureEntryScrollAnchor(): EntryScrollAnchor? {
        val scrollView = entriesScrollView ?: return null
        val container = entriesContainer ?: return EntryScrollAnchor(null, scrollView.scrollY)
        val scrollY = scrollView.scrollY
        for (index in 0 until container.childCount) {
            val child = container.getChildAt(index)
            if (child.bottom >= scrollY) {
                return EntryScrollAnchor(
                    entryId = child.tag as? String,
                    offsetFromTop = scrollY - child.top,
                )
            }
        }
        return EntryScrollAnchor(null, scrollY)
    }

    private fun restoreEntryScrollAnchor(anchor: EntryScrollAnchor?) {
        if (anchor == null) return
        val scrollView = entriesScrollView ?: return
        val container = entriesContainer
        scrollView.post {
            val anchoredTop = anchor.entryId?.let { entryId ->
                container?.findChildByEntryId(entryId)?.top
            }
            val targetY = (anchoredTop?.plus(anchor.offsetFromTop) ?: anchor.offsetFromTop)
                .coerceAtLeast(0)
            scrollView.scrollTo(0, targetY)
        }
    }

    private fun setContentViewWithSystemBars(root: View) {
        setContentView(root)
        val initialPaddingLeft = root.paddingLeft
        val initialPaddingTop = root.paddingTop
        val initialPaddingRight = root.paddingRight
        val initialPaddingBottom = root.paddingBottom
        root.setOnApplyWindowInsetsListener { view, insets ->
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.R) {
                val bars = insets.getInsets(
                    WindowInsets.Type.statusBars() or
                        WindowInsets.Type.navigationBars() or
                        WindowInsets.Type.displayCutout(),
                )
                view.setPadding(
                    initialPaddingLeft + bars.left,
                    initialPaddingTop + bars.top,
                    initialPaddingRight + bars.right,
                    initialPaddingBottom + bars.bottom,
                )
            } else {
                @Suppress("DEPRECATION")
                view.setPadding(
                    initialPaddingLeft + insets.systemWindowInsetLeft,
                    initialPaddingTop + insets.systemWindowInsetTop,
                    initialPaddingRight + insets.systemWindowInsetRight,
                    initialPaddingBottom + insets.systemWindowInsetBottom,
                )
            }
            insets
        }
        root.requestApplyInsets()
    }

    private fun exportTimestamp(): String =
        ExportTimestamp.format(Instant.now())

    private fun formatInstant(value: Instant): String =
        DisplayTimestamp.format(value)

    private fun formatBytes(sizeBytes: Long): String =
        when {
            sizeBytes >= 1024 * 1024 -> text(R.string.file_size_mb, sizeBytes / (1024 * 1024))
            sizeBytes >= 1024 -> text(R.string.file_size_kb, sizeBytes / 1024)
            else -> text(R.string.file_size_b, sizeBytes)
        }

    private fun observeWindowLayout() {
        windowLayoutJob?.cancel()
        windowLayoutJob = layoutScope.launch {
            WindowInfoTracker.getOrCreate(this@MainActivity)
                .windowLayoutInfo(this@MainActivity)
                .collectLatest { info ->
                    val previousFoldInfo = currentFoldInfo()
                    val wasExpanded = isExpandedLayout(previousFoldInfo)
                    val wasTabletop = previousFoldInfo?.isHorizontalSeparating == true
                    windowLayoutInfo = info
                    val nextFoldInfo = currentFoldInfo()
                    val didChangeExpanded = wasExpanded != isExpandedLayout(nextFoldInfo)
                    val didChangePosture = wasTabletop != (nextFoldInfo?.isHorizontalSeparating == true)
                    if (store.isUnlocked && (didChangeExpanded || didChangePosture)) {
                        showHome()
                    }
                }
        }
    }

    private fun isExpandedLayout(foldInfo: FoldInfo? = currentFoldInfo()): Boolean =
        WindowLayoutPolicy.shouldUseTwoPaneLayout(
            widthDp = resources.configuration.screenWidthDp,
            hasSeparatingFold = foldInfo != null,
        )

    private fun currentFoldInfo(): FoldInfo? =
        windowLayoutInfo
            ?.displayFeatures
            ?.filterIsInstance<FoldingFeature>()
            ?.firstOrNull { it.isSeparating }
            ?.let { feature ->
                FoldInfo(
                    orientation = feature.orientation,
                    widthPx = feature.bounds.width(),
                    heightPx = feature.bounds.height(),
                )
            }

    private fun hasHorizontalSeparatingFold(): Boolean =
        currentFoldInfo()?.isHorizontalSeparating == true

    private fun showTagSelectionDialog(
        availableTags: List<String>,
        selectedTags: Set<String>,
        onSelected: (Set<String>) -> Unit,
    ) {
        val selected = selectedTags.toMutableSet()
        val form = formRoot()
        val search = input(text(R.string.search_tags))
        val addButton = toolbarIconButton(R.drawable.ic_add_24, text(R.string.create_tag), accent = true) {}
        val list = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        val selectedStrip = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        var dialog: AlertDialog? = null
        fun exactMatch(query: String): Boolean =
            availableTags.any { it.equals(query.trim(), ignoreCase = true) } ||
                selected.any { it.equals(query.trim(), ignoreCase = true) }
        fun renderSelected() {
            selectedStrip.removeAllViews()
            selectedStrip.addView(label(text(R.string.selected_tags), 12f, uiColor(R.color.ui_muted), Typeface.BOLD))
            selectedStrip.addView(HorizontalScrollView(this).apply {
                isHorizontalScrollBarEnabled = false
                addView(LinearLayout(this@MainActivity).apply {
                    orientation = LinearLayout.HORIZONTAL
                    if (selected.isEmpty()) {
                        addView(label(text(R.string.none), 13f, uiColor(R.color.ui_muted)))
                    } else {
                        selected.sorted().forEachIndexed { index, tag ->
                            addView(pill(tag, selected = true).apply {
                                isClickable = true
                                setOnClickListener {
                                    search.requestFocus()
                                }
                            }, wrapWrap(right = if (index == selected.size - 1) 0 else dp(8)))
                        }
                    }
                })
            }, matchWrap(top = dp(6)))
        }
        fun render(query: String = "") {
            list.removeAllViews()
            val normalizedQuery = query.trim()
            val filtered = (availableTags + selected)
                .distinct()
                .filter { it.contains(normalizedQuery, ignoreCase = true) }
            addButton.visibility = if (normalizedQuery.isNotBlank() && !exactMatch(normalizedQuery)) View.VISIBLE else View.GONE
            if (filtered.isEmpty()) {
                list.addView(label(text(R.string.no_matching_tags), 13f, uiColor(R.color.ui_muted)), matchWrap(top = dp(10)))
            } else {
                filtered.forEach { tag ->
                    list.addView(CheckBox(this).apply {
                        text = tag
                        isChecked = selected.contains(tag)
                        setTextColor(uiColor(R.color.ui_text))
                        setOnCheckedChangeListener { _, checked ->
                            if (checked) {
                                selected += tag
                            } else {
                                selected -= tag
                            }
                            renderSelected()
                        }
                    }, matchWrap(top = dp(6)))
                }
            }
        }
        addButton.setOnClickListener {
            val value = search.text.toString().trim()
            if (value.isBlank()) return@setOnClickListener
            if (store.addTag(value)) {
                selected += value
                renderSelected()
                render(value)
                toast(store.statusMessage ?: text(R.string.saved))
            } else {
                toast(store.statusMessage ?: text(R.string.operation_failed))
            }
        }
        search.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {
                render(s?.toString().orEmpty())
            }
            override fun afterTextChanged(s: Editable?) = Unit
        })
        form.addView(formTitle(text(R.string.choose_tags)))
        form.addView(selectedStrip, matchWrap(top = dp(12)))
        form.addView(LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(search, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
            addView(addButton, wrapWrap(left = dp(8)))
        }, matchWrap(top = dp(12)))
        form.addView(list, matchWrap(top = dp(8)))
        renderSelected()
        render()
        dialog = AlertDialog.Builder(this)
            .setView(ScrollView(this).apply { addView(form) })
            .setPositiveButton(text(R.string.save)) { _, _ -> onSelected(selected) }
            .setNegativeButton(text(R.string.cancel), null)
            .show()
    }

    private fun showCategorySelectionDialog(
        currentCategory: String,
        onSelected: (String) -> Unit,
    ) {
        val options = listOf("") + store.categories()
        val form = formRoot()
        val search = searchInput(text(R.string.search_categories))
        val addButton = toolbarIconButton(R.drawable.ic_add_24, text(R.string.create_category), accent = true) {}
        val list = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        var dialog: AlertDialog? = null
        fun exactMatch(query: String): Boolean =
            options.any { it.equals(query.trim(), ignoreCase = true) }
        fun render(query: String = "") {
            list.removeAllViews()
            val normalizedQuery = query.trim()
            addButton.visibility = if (normalizedQuery.isNotBlank() && !exactMatch(normalizedQuery)) View.VISIBLE else View.GONE
            val filtered = options.filter { option ->
                categoryDisplayName(option).contains(normalizedQuery, ignoreCase = true)
            }
            if (filtered.isEmpty()) {
                list.addView(label(text(R.string.no_matching_categories), 13f, uiColor(R.color.ui_muted)), matchWrap(top = dp(10)))
            } else {
                filtered.forEach { category ->
                    list.addView(selectBoxText(categoryDisplayName(category), selected = category == currentCategory) {
                        onSelected(category)
                        dialog?.dismiss()
                    }, matchWrap(top = compactGap()))
                }
            }
        }
        addButton.setOnClickListener {
            val value = search.text.toString().trim()
            if (value.isBlank()) return@setOnClickListener
            if (store.addCategory(value)) {
                onSelected(value)
                dialog?.dismiss()
                toast(store.statusMessage ?: text(R.string.saved))
            } else {
                toast(store.statusMessage ?: text(R.string.operation_failed))
            }
        }
        search.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {
                render(s?.toString().orEmpty())
            }
            override fun afterTextChanged(s: Editable?) = Unit
        })
        form.addView(formTitle(text(R.string.category)))
        form.addView(LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(search, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
            addView(addButton, wrapWrap(left = dp(8)))
        }, matchWrap(top = compactGap()))
        form.addView(list, matchWrap(top = compactGap()))
        render()
        dialog = AlertDialog.Builder(this)
            .setView(ScrollView(this).apply { addView(form) })
            .setNegativeButton(text(R.string.cancel), null)
            .show()
    }

    private fun card(): LinearLayout =
        LinearLayout(this).apply {
            background = rounded(uiColor(R.color.ui_surface), dp(18), uiColor(R.color.ui_stroke))
        }

    private fun input(
        hintText: String,
        secret: Boolean = false,
        inputType: Int = InputType.TYPE_CLASS_TEXT,
        singleLine: Boolean = true,
    ): EditText =
        EditText(this).apply {
            hint = hintText
            textSize = 15f
            setSingleLine(singleLine)
            if (!singleLine) {
                minLines = 3
                maxLines = 8
                gravity = Gravity.TOP or Gravity.START
            }
            setTextColor(uiColor(R.color.ui_text))
            setHintTextColor(uiColor(R.color.ui_muted))
            setPadding(dp(14), if (singleLine) 0 else dp(12), dp(14), if (singleLine) 0 else dp(12))
            minHeight = if (singleLine) dp(52) else dp(120)
            background = rounded(uiColor(R.color.ui_surface_alt), dp(12), uiColor(R.color.ui_stroke))
            this.inputType = if (secret) {
                InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
            } else if (!singleLine) {
                inputType or InputType.TYPE_TEXT_FLAG_MULTI_LINE or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
            } else {
                inputType
            }
        }

    private fun actionButton(textValue: String, primary: Boolean, onClick: () -> Unit): Button =
        actionButton(textValue, primary, compact = false, onClick = onClick)

    private fun actionButton(textValue: String, primary: Boolean, compact: Boolean, onClick: () -> Unit): Button =
        Button(this).apply {
            text = textValue
            textSize = if (compact) 12f else 13f
            isAllCaps = false
            minHeight = if (compact) dp(40) else dp(44)
            minWidth = if (compact) dp(72) else dp(88)
            setPadding(if (compact) dp(12) else dp(14), 0, if (compact) dp(12) else dp(14), 0)
            setTextColor(if (primary) Color.WHITE else uiColor(R.color.ui_text))
            background = rounded(if (primary) uiColor(R.color.ui_accent) else uiColor(R.color.ui_surface_alt), dp(12), if (primary) uiColor(R.color.ui_accent) else uiColor(R.color.ui_stroke))
            setOnClickListener { onClick() }
        }

    private fun compactTextButton(
        textValue: String,
        selected: Boolean = false,
        onClick: () -> Unit,
    ): TextView =
        TextView(this).apply {
            text = textValue
            textSize = compactTextSize()
            minHeight = compactControlHeight()
            minWidth = dp(if (isCompactWidth()) 52 else 64)
            gravity = Gravity.CENTER
            setPadding(compactHorizontalPadding(), 0, compactHorizontalPadding(), 0)
            setTextColor(if (selected) Color.WHITE else uiColor(R.color.ui_text))
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            background = rounded(if (selected) uiColor(R.color.ui_accent) else uiColor(R.color.ui_surface_alt), compactRadius(), if (selected) uiColor(R.color.ui_accent) else uiColor(R.color.ui_stroke))
            isClickable = true
            isFocusable = true
            setOnClickListener { onClick() }
        }

    private fun selectBoxText(
        textValue: String,
        selected: Boolean = false,
        onClick: () -> Unit,
    ): TextView =
        TextView(this).apply {
            text = textValue
            textSize = 14f
            minHeight = dp(48)
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(14), 0, dp(14), 0)
            setTextColor(if (selected) Color.WHITE else uiColor(R.color.ui_text))
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            background = rounded(if (selected) uiColor(R.color.ui_accent) else uiColor(R.color.ui_surface_alt), dp(12), if (selected) uiColor(R.color.ui_accent) else uiColor(R.color.ui_stroke))
            isClickable = true
            isFocusable = true
            setOnClickListener { onClick() }
        }

    private fun searchInput(hintText: String): EditText =
        input(hintText).apply {
            minHeight = searchControlHeight()
            textSize = if (isCompactWidth()) 13f else 14f
            setPadding(dp(if (isCompactWidth()) 10 else 12), dp(if (isCompactWidth()) 4 else 6), dp(if (isCompactWidth()) 10 else 12), dp(if (isCompactWidth()) 4 else 6))
        }

    private fun filterSearchInput(hintText: String): EditText =
        EditText(this).apply {
            hint = hintText
            textSize = if (isCompactWidth()) 14f else 15f
            setSingleLine(true)
            setTextColor(uiColor(R.color.ui_text))
            setHintTextColor(uiColor(R.color.ui_muted))
            setPadding(0, 0, 0, 0)
            minHeight = 0
            background = null
            inputType = InputType.TYPE_CLASS_TEXT
        }

    private fun toolbarIconButton(
        iconRes: Int,
        description: String,
        accent: Boolean = false,
        onClick: (View) -> Unit,
    ): ImageButton =
        ImageButton(this).apply {
            contentDescription = description
            setImageResource(iconRes)
            setColorFilter(if (accent) uiColor(R.color.ui_accent) else uiColor(R.color.ui_text))
            scaleType = ImageView.ScaleType.CENTER
            minimumWidth = dp(44)
            minimumHeight = dp(44)
            setPadding(dp(10), dp(10), dp(10), dp(10))
            background = iconRipple()
            isClickable = true
            isFocusable = true
            setOnClickListener { onClick(it) }
        }

    private fun filterChip(
        textValue: String,
        selected: Boolean,
        showCheck: Boolean = false,
        onClick: () -> Unit,
    ): TextView =
        TextView(this).apply {
            text = if (selected && showCheck) "✓  $textValue" else textValue
            textSize = if (isCompactWidth()) 13f else 14f
            minHeight = chipHeight()
            minWidth = dp(if (isCompactWidth()) 70 else 82)
            gravity = Gravity.CENTER
            setPadding(dp(if (isCompactWidth()) 14 else 18), 0, dp(if (isCompactWidth()) 14 else 18), 0)
            setTextColor(if (selected) Color.WHITE else uiColor(R.color.ui_text))
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            background = rounded(if (selected) uiColor(R.color.ui_accent) else uiColor(R.color.ui_surface_alt), dp(999), uiColor(R.color.ui_stroke))
            isClickable = true
            isFocusable = true
            setOnClickListener { onClick() }
        }

    private fun pill(textValue: String, selected: Boolean): TextView =
        label(textValue, 11f, if (selected) Color.WHITE else uiColor(R.color.ui_muted), Typeface.BOLD).apply {
            setPadding(dp(10), dp(5), dp(10), dp(5))
            background = rounded(if (selected) uiColor(R.color.ui_accent) else uiColor(R.color.ui_surface), dp(999), if (selected) uiColor(R.color.ui_accent) else uiColor(R.color.ui_stroke))
        }

    private fun securityTag(textValue: String): TextView =
        label(textValue, 11f, uiColor(R.color.ui_accent), Typeface.BOLD).apply {
            setPadding(dp(9), dp(4), dp(9), dp(4))
            maxLines = 1
            ellipsize = android.text.TextUtils.TruncateAt.END
            background = rounded(uiColor(R.color.ui_surface_alt), dp(999), uiColor(R.color.ui_stroke))
        }

    private fun formRoot(): LinearLayout =
        LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(20), dp(20), dp(8))
            minimumWidth = dp(320)
        }

    private fun showAnchoredPopup(
        anchor: View?,
        content: View,
        maxWidth: Int = dp(360),
        maxHeight: Int = ViewGroup.LayoutParams.WRAP_CONTENT,
    ): PopupWindow {
        val container = card().apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, 0, 0, dp(12))
            addView(content, LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                maxHeight,
            ))
        }
        val popup = PopupWindow(
            container,
            resources.displayMetrics.widthPixels.coerceAtMost(maxWidth),
            ViewGroup.LayoutParams.WRAP_CONTENT,
            true,
        ).apply {
            isOutsideTouchable = true
            elevation = dp(8).toFloat()
            setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
        }
        val target = anchor ?: window.decorView
        val popupWidth = resources.displayMetrics.widthPixels.coerceAtMost(maxWidth)
        val xOffset = if (anchor == null) {
            0
        } else {
            val location = IntArray(2)
            anchor.getLocationOnScreen(location)
            val overflow = location[0] + popupWidth - resources.displayMetrics.widthPixels + dp(12)
            if (overflow > 0) -overflow else 0
        }
        popup.showAsDropDown(target, xOffset, dp(6), Gravity.NO_GRAVITY)
        return popup
    }

    private fun formTitle(textValue: String): TextView =
        label(textValue, 22f, uiColor(R.color.ui_text), Typeface.BOLD)

    private fun sectionTitle(textValue: String): TextView =
        label(textValue, 13f, uiColor(R.color.ui_accent), Typeface.BOLD)

    private fun label(
        textValue: String,
        size: Float,
        color: Int,
        style: Int = Typeface.NORMAL,
    ): TextView =
        TextView(this).apply {
            text = textValue
            textSize = size
            setTextColor(color)
            typeface = Typeface.create(Typeface.DEFAULT, style)
        }

    private fun text(resourceId: Int): String =
        getString(resourceId)

    private fun text(resourceId: Int, vararg args: Any): String =
        getString(resourceId, *args)

    private fun uiColor(resourceId: Int): Int =
        getColor(resourceId)

    private fun rounded(fill: Int, radius: Int, stroke: Int): GradientDrawable =
        GradientDrawable().apply {
            shape = GradientDrawable.RECTANGLE
            setColor(fill)
            cornerRadius = radius.toFloat()
            setStroke(dp(1), stroke)
        }

    private fun iconRipple(): RippleDrawable =
        RippleDrawable(
            ColorStateList.valueOf(uiColor(R.color.ui_selected)),
            null,
            GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(Color.WHITE)
            },
        )

    private fun matchWrap(
        left: Int = 0,
        top: Int = 0,
        right: Int = 0,
        bottom: Int = 0,
    ): LinearLayout.LayoutParams =
        LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.WRAP_CONTENT
        ).apply {
            setMargins(left, top, right, bottom)
        }

    private fun wrapWrap(
        left: Int = 0,
        top: Int = 0,
        right: Int = 0,
        bottom: Int = 0,
    ): LinearLayout.LayoutParams =
        LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT,
            ViewGroup.LayoutParams.WRAP_CONTENT
        ).apply {
            setMargins(left, top, right, bottom)
        }

    private fun dp(value: Int): Int =
        (value * resources.displayMetrics.density).toInt()

    private fun isCompactWidth(): Boolean =
        resources.displayMetrics.widthPixels < dp(420)

    private fun compactControlHeight(): Int =
        dp(if (isCompactWidth()) 28 else 32)

    private fun searchControlHeight(): Int =
        dp(if (isCompactWidth()) 42 else 48)

    private fun filterSearchHeight(): Int =
        dp(if (isCompactWidth()) 50 else 58)

    private fun chipHeight(): Int =
        dp(if (isCompactWidth()) 38 else 44)

    private fun compactHorizontalPadding(): Int =
        dp(if (isCompactWidth()) 8 else 10)

    private fun compactGap(): Int =
        dp(if (isCompactWidth()) 6 else 8)

    private fun compactRadius(): Int =
        dp(if (isCompactWidth()) 8 else 10)

    private fun compactTextSize(): Float =
        if (isCompactWidth()) 11f else 12f

    private fun toast(message: String) {
        Toast.makeText(this, message, Toast.LENGTH_SHORT).show()
    }

    private fun categoryDisplayName(category: String): String =
        category.ifBlank { text(R.string.uncategorized) }

    private fun safeExportName(value: String): String {
        val safeName = value.trim()
            .split(Regex("""[\\/:*?"<>|\s]+"""))
            .filter { it.isNotEmpty() }
            .joinToString("_")
        return safeName.ifEmpty { "untitled" }
    }

    private enum class PendingImportKind {
        SNAPSHOT,
        SCOPED
    }

    private data class ImportResultMessage(
        val success: Boolean,
        val message: String,
    )

    private data class UnlockResult(
        val success: Boolean,
        val message: String,
    )

    private data class EntryScrollAnchor(
        val entryId: String?,
        val offsetFromTop: Int,
    )

    private enum class TaxonomyKind {
        CATEGORY,
        TAG
    }

    private data class FoldInfo(
        val orientation: FoldingFeature.Orientation,
        val widthPx: Int,
        val heightPx: Int,
    ) {
        val isHorizontalSeparating: Boolean =
            orientation == FoldingFeature.Orientation.HORIZONTAL
    }

    private companion object {
        const val RequestCodeCreateDocument = 4101
        const val RequestCodeOpenDocument = 4102
        const val AppPreferencesName = "password_manager_android_preferences"
        const val PrefBiometricUnlockEnabled = "biometric_unlock_enabled"
        const val PrefIdleAutoLockMinutes = "idle_auto_lock_minutes"
        const val MaxBiometricFailures = 3
        const val IdleLockCheckIntervalMs = 10_000L
        const val AutoSyncCheckIntervalMs = 1_000L
        val ExportTimestamp: DateTimeFormatter = DateTimeFormatter
            .ofPattern("yyyyMMdd-HHmmss")
            .withZone(ZoneOffset.UTC)
        val DisplayTimestamp: DateTimeFormatter = DateTimeFormatter
            .ofPattern("yyyy-MM-dd HH:mm")
            .withZone(ZoneId.systemDefault())
    }
}

private fun VaultEntry.toDraft(): EntryDraft =
    when (payload) {
        is VaultPayload.Credential -> EntryDraft(
            label = label,
            type = type,
            category = payload.category,
            tags = payload.tags,
            customFields = customFields,
            credential = payload.value,
        )
        is VaultPayload.Server -> EntryDraft(
            label = label,
            type = type,
            category = payload.category,
            tags = payload.tags,
            customFields = customFields,
            server = payload.value,
        )
        is VaultPayload.Service -> EntryDraft(
            label = label,
            type = type,
            category = payload.category,
            tags = payload.tags,
            customFields = customFields,
            service = payload.value,
        )
    }

private data class PayloadFieldSpec(
    val label: String,
    val value: String,
    val secret: Boolean = false,
    val multiline: Boolean = false,
)

private data class EntryExportField(
    val id: String,
    val title: String,
)

private fun payloadFieldSpecs(type: VaultEntryType, draft: EntryDraft, activity: Activity): List<PayloadFieldSpec> =
    when (type) {
        VaultEntryType.CREDENTIAL -> listOf(
            PayloadFieldSpec(activity.getString(R.string.username), draft.credential.username),
            PayloadFieldSpec(activity.getString(R.string.password), draft.credential.password, secret = true),
            PayloadFieldSpec(activity.getString(R.string.service_accounts_format_hint), formatServiceAccounts(draft.credential.accounts), multiline = true),
            PayloadFieldSpec(activity.getString(R.string.token), draft.credential.token),
            PayloadFieldSpec(activity.getString(R.string.app_id), draft.credential.appId),
            PayloadFieldSpec(activity.getString(R.string.access_key), draft.credential.accessKey),
            PayloadFieldSpec(activity.getString(R.string.secret_key), draft.credential.secretKey, secret = true),
            PayloadFieldSpec(activity.getString(R.string.notes), draft.credential.notes, multiline = true),
        )
        VaultEntryType.SERVER -> listOf(
            PayloadFieldSpec(activity.getString(R.string.name), draft.server.name),
            PayloadFieldSpec(activity.getString(R.string.ip_address), draft.server.ipAddress),
            PayloadFieldSpec(activity.getString(R.string.port), draft.server.port),
            PayloadFieldSpec(activity.getString(R.string.username), draft.server.username),
            PayloadFieldSpec(activity.getString(R.string.password), draft.server.password, secret = true),
            PayloadFieldSpec(activity.getString(R.string.service_accounts_format_hint), formatServiceAccounts(draft.server.accounts), multiline = true),
            PayloadFieldSpec(activity.getString(R.string.basic_config), draft.server.basicConfig, multiline = true),
            PayloadFieldSpec(activity.getString(R.string.operating_system), draft.server.operatingSystem),
            PayloadFieldSpec(activity.getString(R.string.location), draft.server.location),
            PayloadFieldSpec(activity.getString(R.string.notes), draft.server.notes, multiline = true),
        )
        VaultEntryType.SERVICE -> listOf(
            PayloadFieldSpec(activity.getString(R.string.name), draft.service.name),
            PayloadFieldSpec(activity.getString(R.string.connection_address), draft.service.connectionAddress),
            PayloadFieldSpec(activity.getString(R.string.connection_port), draft.service.connectionPort),
            PayloadFieldSpec(activity.getString(R.string.account_id), draft.service.accountId.orEmpty()),
            PayloadFieldSpec(activity.getString(R.string.server_ids_comma_separated), draft.service.serverIds.joinToString(", ")),
            PayloadFieldSpec(activity.getString(R.string.service_accounts_format_hint), formatServiceAccounts(draft.service.accounts), multiline = true),
            PayloadFieldSpec(activity.getString(R.string.notes), draft.service.notes, multiline = true),
        )
    }

private fun VaultEntry.exportFields(activity: Activity): List<EntryExportField> {
    val fields = mutableListOf(
        EntryExportField("label", activity.getString(R.string.label_field)),
        EntryExportField("category", activity.getString(R.string.category)),
        EntryExportField("tags", activity.getString(R.string.tags)),
    )
    when (payload) {
        is VaultPayload.Credential -> fields += listOf(
            EntryExportField("credential.username", activity.getString(R.string.username)),
            EntryExportField("credential.password", activity.getString(R.string.password)),
            EntryExportField("credential.accounts", activity.getString(R.string.service_accounts)),
            EntryExportField("credential.token", activity.getString(R.string.token)),
            EntryExportField("credential.appId", activity.getString(R.string.app_id)),
            EntryExportField("credential.accessKey", activity.getString(R.string.access_key)),
            EntryExportField("credential.secretKey", activity.getString(R.string.secret_key)),
            EntryExportField("credential.notes", activity.getString(R.string.notes)),
        )
        is VaultPayload.Server -> fields += listOf(
            EntryExportField("server.name", activity.getString(R.string.name)),
            EntryExportField("server.ipAddress", activity.getString(R.string.ip_address)),
            EntryExportField("server.port", activity.getString(R.string.port)),
            EntryExportField("server.username", activity.getString(R.string.username)),
            EntryExportField("server.password", activity.getString(R.string.password)),
            EntryExportField("server.accounts", activity.getString(R.string.service_accounts)),
            EntryExportField("server.basicConfig", activity.getString(R.string.basic_config)),
            EntryExportField("server.operatingSystem", activity.getString(R.string.os)),
            EntryExportField("server.location", activity.getString(R.string.location)),
            EntryExportField("server.notes", activity.getString(R.string.notes)),
        )
        is VaultPayload.Service -> fields += listOf(
            EntryExportField("service.name", activity.getString(R.string.name)),
            EntryExportField("service.connectionAddress", activity.getString(R.string.connection_address)),
            EntryExportField("service.connectionPort", activity.getString(R.string.connection_port)),
            EntryExportField("service.accountId", activity.getString(R.string.account_id)),
            EntryExportField("service.serverIds", activity.getString(R.string.server_ids)),
            EntryExportField("service.accounts", activity.getString(R.string.service_accounts)),
            EntryExportField("service.notes", activity.getString(R.string.notes)),
        )
    }
    fields += customFields.map { field ->
        EntryExportField("custom.${field.id}", field.name.ifBlank { activity.getString(R.string.custom_field) })
    }
    return fields
}

private fun credentialPayload(inputs: List<EditText>): CredentialPayload =
    CredentialPayload(
        username = inputs.valueAt(0),
        password = inputs.valueAt(1),
        accounts = parseServiceAccounts(inputs.valueAt(2)),
        token = inputs.valueAt(3),
        appId = inputs.valueAt(4),
        accessKey = inputs.valueAt(5),
        secretKey = inputs.valueAt(6),
        notes = inputs.valueAt(7),
    )

private fun serverPayload(inputs: List<EditText>): ServerPayload =
    ServerPayload(
        name = inputs.valueAt(0),
        ipAddress = inputs.valueAt(1),
        port = inputs.valueAt(2),
        username = inputs.valueAt(3),
        password = inputs.valueAt(4),
        accounts = parseServiceAccounts(inputs.valueAt(5)),
        basicConfig = inputs.valueAt(6),
        operatingSystem = inputs.valueAt(7),
        location = inputs.valueAt(8),
        notes = inputs.valueAt(9),
    )

private fun servicePayload(inputs: List<EditText>): ServicePayload =
    ServicePayload(
        name = inputs.valueAt(0),
        connectionAddress = inputs.valueAt(1),
        connectionPort = inputs.valueAt(2),
        accountId = inputs.valueAt(3).ifBlank { null },
        serverIds = inputs.valueAt(4).split(",").map { it.trim() }.filter { it.isNotEmpty() },
        accounts = parseServiceAccounts(inputs.valueAt(5)),
        notes = inputs.valueAt(6),
    )

private fun List<EditText>.valueAt(index: Int): String =
    getOrNull(index)?.text?.toString().orEmpty()

private fun LinearLayout.findChildByEntryId(entryId: String): View? {
    for (index in 0 until childCount) {
        val child = getChildAt(index)
        if (child.tag == entryId) {
            return child
        }
    }
    return null
}

private fun VaultEntry.detailPairs(activity: MainActivity): List<Pair<String, String>> =
    when (val currentPayload = payload) {
        is VaultPayload.Credential -> listOf(
            activity.getString(R.string.username) to currentPayload.value.username,
            activity.getString(R.string.password) to currentPayload.value.password,
            activity.getString(R.string.service_accounts) to formatServiceAccountsForDisplay(currentPayload.value.accounts),
            activity.getString(R.string.token) to currentPayload.value.token,
            activity.getString(R.string.app_id) to currentPayload.value.appId,
            activity.getString(R.string.access_key) to currentPayload.value.accessKey,
            activity.getString(R.string.secret_key) to currentPayload.value.secretKey,
            activity.getString(R.string.notes) to currentPayload.value.notes,
        )
        is VaultPayload.Server -> listOf(
            activity.getString(R.string.name) to currentPayload.value.name,
            activity.getString(R.string.ip_address) to currentPayload.value.ipAddress,
            activity.getString(R.string.port) to currentPayload.value.port,
            activity.getString(R.string.username) to currentPayload.value.username,
            activity.getString(R.string.password) to currentPayload.value.password,
            activity.getString(R.string.service_accounts) to formatServiceAccountsForDisplay(currentPayload.value.accounts),
            activity.getString(R.string.basic_config) to currentPayload.value.basicConfig,
            activity.getString(R.string.os) to currentPayload.value.operatingSystem,
            activity.getString(R.string.location) to currentPayload.value.location,
            activity.getString(R.string.notes) to currentPayload.value.notes,
        )
        is VaultPayload.Service -> listOf(
            activity.getString(R.string.name) to currentPayload.value.name,
            activity.getString(R.string.connection_address) to currentPayload.value.connectionAddress,
            activity.getString(R.string.connection_port) to currentPayload.value.connectionPort,
            activity.getString(R.string.account_id) to currentPayload.value.accountId.orEmpty(),
            activity.getString(R.string.server_ids) to currentPayload.value.serverIds.joinToString(", "),
            activity.getString(R.string.service_accounts) to formatServiceAccountsForDisplay(currentPayload.value.accounts),
            activity.getString(R.string.notes) to currentPayload.value.notes,
        )
    } + customFields.map { field ->
        field.name.ifBlank { activity.getString(R.string.custom_field) } to field.value
    }

private class SimpleTextWatcher(
    private val onChanged: (String) -> Unit,
) : TextWatcher {
    override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
    override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {
        onChanged(s?.toString().orEmpty())
    }
    override fun afterTextChanged(s: Editable?) = Unit
}

private fun ImportConflictStrategy.localizedTitle(activity: Activity): String =
    activity.getString(
        when (this) {
            ImportConflictStrategy.KEEP_COPY -> R.string.import_strategy_keep_copy
            ImportConflictStrategy.OVERWRITE -> R.string.import_strategy_overwrite
            ImportConflictStrategy.SKIP -> R.string.import_strategy_skip
        }
    )

private fun SyncProviderType.localizedTitle(activity: Activity): String =
    activity.getString(
        when (this) {
            SyncProviderType.NONE -> R.string.sync_provider_none
            SyncProviderType.WEBDAV -> R.string.sync_provider_webdav
            SyncProviderType.S3_PRESIGNED -> R.string.sync_provider_s3_presigned
            SyncProviderType.NAS_WEBDAV -> R.string.sync_provider_nas_webdav
            SyncProviderType.TENCENT_COS -> R.string.sync_provider_tencent_cos
            SyncProviderType.ALIYUN_OSS -> R.string.sync_provider_aliyun_oss
        }
    )

private fun VaultEntryType.localizedTitle(activity: Activity): String =
    activity.getString(
        when (this) {
            VaultEntryType.CREDENTIAL -> R.string.entry_type_account
            VaultEntryType.SERVER -> R.string.entry_type_server
            VaultEntryType.SERVICE -> R.string.entry_type_service
        }
    )

private fun SyncIntervalUnit.localizedTitle(activity: Activity): String =
    activity.getString(
        when (this) {
            SyncIntervalUnit.SECONDS -> R.string.auto_sync_interval_unit_seconds
            SyncIntervalUnit.MINUTES -> R.string.auto_sync_interval_unit_minutes
        }
    )

private fun SyncSettingsConflictStrategy.localizedTitle(activity: Activity): String =
    activity.getString(
        when (this) {
            SyncSettingsConflictStrategy.REMOTE_WINS -> R.string.sync_strategy_remote_wins
            SyncSettingsConflictStrategy.LOCAL_WINS -> R.string.sync_strategy_local_wins
            SyncSettingsConflictStrategy.KEEP_BOTH -> R.string.sync_strategy_keep_both
        }
    )

internal fun formatServiceAccounts(accounts: List<ServiceAccount>): String =
    accounts.joinToString("; ") { account ->
        listOf(account.username, account.password, account.note).joinToString(":")
    }

internal fun formatServiceAccountsForDisplay(accounts: List<ServiceAccount>): String =
    accounts.joinToString("\n") { account ->
        "${account.username}: ${account.password}${if (account.note.isBlank()) "" else " - ${account.note}"}"
    }

internal fun parseServiceAccounts(raw: String): List<ServiceAccount> =
    raw.split(";")
        .map { it.trim() }
        .filter { it.isNotEmpty() }
        .mapNotNull { entry ->
            val parts = entry.split(":", limit = 3).map { it.trim() }
            val username = parts.getOrNull(0).orEmpty()
            if (username.isBlank()) {
                null
            } else {
                ServiceAccount(
                    username = username,
                    password = parts.getOrNull(1).orEmpty(),
                    note = parts.getOrNull(2).orEmpty(),
                )
            }
        }
