import {
  BACKUP_STORAGE_KEY,
  SYNC_SETTINGS_KEY,
  VAULT_STORAGE_KEY,
  applySyncSecrets,
  createBackup,
  createVaultEnvelope,
  defaultSnapshot,
  defaultSyncSettings,
  decryptVaultEnvelope,
  deleteEntry,
  exportSnapshot,
  filterEntries,
  importSnapshot,
  makeRemoteSyncClient,
  makeEntry,
  rebuildCollections,
  redactedSyncSettings,
  synchronizeSnapshot,
  syncSecrets,
  updateEntry,
  verifyTotp
} from "./vault-core.mjs";

const state = {
  envelope: readJson(VAULT_STORAGE_KEY),
  snapshot: defaultSnapshot(),
  syncSettings: loadSyncSettings(),
  backups: readJson(BACKUP_STORAGE_KEY) ?? [],
  password: "",
  selectedId: null,
  filter: "all",
  editingId: null
};

const elements = {
  unlockScreen: document.querySelector("#unlock-screen"),
  vaultScreen: document.querySelector("#vault-screen"),
  unlockForm: document.querySelector("#unlock-form"),
  masterPassword: document.querySelector("#master-password"),
  confirmRow: document.querySelector("#confirm-row"),
  confirmPassword: document.querySelector("#confirm-password"),
  totpRow: document.querySelector("#totp-row"),
  totpCode: document.querySelector("#totp-code"),
  unlockSubmit: document.querySelector("#unlock-submit"),
  authMessage: document.querySelector("#auth-message"),
  searchInput: document.querySelector("#search-input"),
  filters: document.querySelectorAll(".filter"),
  entryList: document.querySelector("#entry-list"),
  detailPanel: document.querySelector("#detail-panel"),
  itemCount: document.querySelector("#item-count"),
  syncStatus: document.querySelector("#sync-status"),
  entryDialog: document.querySelector("#entry-dialog"),
  entryForm: document.querySelector("#entry-form"),
  entryTitle: document.querySelector("#entry-dialog-title"),
  entryLabel: document.querySelector("#entry-label"),
  entryType: document.querySelector("#entry-type"),
  entryUsername: document.querySelector("#entry-username"),
  entrySecret: document.querySelector("#entry-secret"),
  entryCategory: document.querySelector("#entry-category"),
  entryTags: document.querySelector("#entry-tags"),
  entryNotes: document.querySelector("#entry-notes"),
  settingsDialog: document.querySelector("#settings-dialog"),
  settingsForm: document.querySelector("#settings-form"),
  requireTotp: document.querySelector("#require-totp"),
  totpSecret: document.querySelector("#totp-secret"),
  syncProvider: document.querySelector("#sync-provider"),
  webdavUrl: document.querySelector("#webdav-url"),
  webdavUsername: document.querySelector("#webdav-username"),
  webdavPassword: document.querySelector("#webdav-password"),
  webdavPath: document.querySelector("#webdav-path"),
  presignedDownloadUrl: document.querySelector("#presigned-download-url"),
  presignedUploadUrl: document.querySelector("#presigned-upload-url"),
  importFile: document.querySelector("#import-file")
};

renderUnlock();
registerServiceWorker();

elements.unlockForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  const password = elements.masterPassword.value;
  try {
    if (!state.envelope) {
      if (!password || password !== elements.confirmPassword.value) {
        throw new Error("Master password is empty or confirmation does not match.");
      }
      state.snapshot = defaultSnapshot();
      state.envelope = await createVaultEnvelope(password, state.snapshot);
      state.password = password;
      persistEnvelope();
      showVault();
      return;
    }
    const snapshot = await decryptVaultEnvelope(password, state.envelope);
    if (snapshot.security?.requireTotp) {
      const verified = await verifyTotp(snapshot.security.totpSecret, elements.totpCode.value);
      if (!verified) throw new Error("2FA code is invalid.");
    }
    state.snapshot = snapshot;
    state.password = password;
    showVault();
  } catch (error) {
    elements.authMessage.textContent = error.message;
  }
});

document.querySelector("#lock-button").addEventListener("click", () => {
  state.password = "";
  state.snapshot = defaultSnapshot();
  state.selectedId = null;
  renderUnlock();
});

document.querySelector("#add-button").addEventListener("click", () => openEntryDialog());
document.querySelector("#entry-cancel").addEventListener("click", () => elements.entryDialog.close());
document.querySelector("#settings-cancel").addEventListener("click", () => elements.settingsDialog.close());
document.querySelector("#settings-button").addEventListener("click", openSettingsDialog);
document.querySelector("#backup-button").addEventListener("click", runBackup);
document.querySelector("#restore-button").addEventListener("click", restoreLatestBackup);
document.querySelector("#export-button").addEventListener("click", downloadSnapshot);
document.querySelector("#import-button").addEventListener("click", () => elements.importFile.click());
document.querySelector("#sync-button").addEventListener("click", syncNow);
elements.searchInput.addEventListener("input", renderVault);

for (const filter of elements.filters) {
  filter.addEventListener("click", () => {
    state.filter = filter.dataset.filter;
    renderVault();
  });
}

elements.entryForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  const draft = {
    label: elements.entryLabel.value,
    type: elements.entryType.value,
    username: elements.entryUsername.value,
    secret: elements.entrySecret.value,
    category: elements.entryCategory.value,
    tags: elements.entryTags.value,
    notes: elements.entryNotes.value
  };
  if (state.editingId) {
    state.snapshot.entries = state.snapshot.entries.map((entry) =>
      entry.id === state.editingId ? updateEntry(entry, draft) : entry
    );
  } else {
    const entry = makeEntry(draft);
    state.snapshot.entries.push(entry);
    state.selectedId = entry.id;
  }
  await persistSnapshot();
  elements.entryDialog.close();
  renderVault();
});

elements.settingsForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  state.snapshot.security = {
    requireTotp: elements.requireTotp.checked,
    totpSecret: elements.totpSecret.value.trim()
  };
  state.syncSettings = {
    ...state.syncSettings,
    providerType: elements.syncProvider.value,
    webdavUrl: elements.webdavUrl.value.trim(),
    webdavUsername: elements.webdavUsername.value.trim(),
    webdavPassword: elements.webdavPassword.value,
    webdavPath: elements.webdavPath.value.trim() || "/vault.json",
    presignedDownloadUrl: elements.presignedDownloadUrl.value.trim(),
    presignedUploadUrl: elements.presignedUploadUrl.value.trim()
  };
  saveSyncSettings();
  await persistSnapshot();
  elements.settingsDialog.close();
  renderVault();
});

elements.importFile.addEventListener("change", async () => {
  const file = elements.importFile.files?.[0];
  if (!file) return;
  state.snapshot = importSnapshot(await file.text());
  state.selectedId = null;
  await persistSnapshot();
  elements.importFile.value = "";
  renderVault();
});

function renderUnlock() {
  const hasVault = Boolean(state.envelope);
  elements.unlockScreen.hidden = false;
  elements.vaultScreen.hidden = true;
  elements.confirmRow.hidden = hasVault;
  elements.unlockSubmit.textContent = hasVault ? "Unlock" : "Create Vault";
  elements.totpRow.hidden = !hasVault;
  elements.authMessage.textContent = hasVault ? "Encrypted vault found." : "";
}

function showVault() {
  elements.unlockScreen.hidden = true;
  elements.vaultScreen.hidden = false;
  renderVault();
}

function renderVault() {
  const collections = rebuildCollections(state.snapshot.entries);
  state.snapshot.categories = collections.categories;
  state.snapshot.tags = collections.tags;
  elements.syncStatus.textContent = state.snapshot.syncStatus;
  for (const filter of elements.filters) {
    filter.classList.toggle("active", filter.dataset.filter === state.filter);
  }
  const entries = filterEntries(state.snapshot.entries, elements.searchInput.value, state.filter);
  elements.itemCount.textContent = `${entries.length} active ${entries.length === 1 ? "entry" : "entries"}`;
  elements.entryList.replaceChildren(...entries.map(entryRow));
  renderDetail();
}

function entryRow(entry) {
  const button = document.createElement("button");
  button.className = "entry-row";
  button.classList.toggle("selected", entry.id === state.selectedId);
  button.type = "button";
  button.innerHTML = `<strong>${escapeHtml(entry.label)}</strong><span>${entry.type} · ${escapeHtml(entry.payload.category || "Uncategorized")}</span>`;
  button.addEventListener("click", () => {
    state.selectedId = entry.id;
    renderVault();
  });
  return button;
}

function renderDetail() {
  const entry = state.snapshot.entries.find((item) => item.id === state.selectedId && !item.isDeleted);
  if (!entry) {
    elements.detailPanel.innerHTML = '<p class="empty-state">Select an entry to view details.</p>';
    return;
  }
  const secret = entry.payload.credential?.password ?? entry.payload.server?.password ?? "";
  elements.detailPanel.innerHTML = `
    <div class="detail-header">
      <div>
        <h2>${escapeHtml(entry.label)}</h2>
        <p>${entry.type} · ${escapeHtml(entry.payload.category || "Uncategorized")}</p>
      </div>
      <div class="detail-actions">
        <button id="edit-selected" type="button">Edit</button>
        <button id="delete-selected" type="button" class="danger">Delete</button>
      </div>
    </div>
    <dl class="detail-list">
      <dt>Username / name</dt>
      <dd>${escapeHtml(entry.payload.credential?.username ?? entry.payload.server?.username ?? entry.payload.service?.name ?? "")}</dd>
      <dt>Password / secret</dt>
      <dd>${secret ? "••••••••" : "None"}</dd>
      <dt>Tags</dt>
      <dd>${escapeHtml((entry.payload.tags ?? []).join(", ") || "None")}</dd>
      <dt>Notes</dt>
      <dd>${escapeHtml(entry.payload.credential?.notes ?? entry.payload.server?.notes ?? entry.payload.service?.notes ?? "")}</dd>
    </dl>
  `;
  elements.detailPanel.querySelector("#edit-selected").addEventListener("click", () => openEntryDialog(entry));
  elements.detailPanel.querySelector("#delete-selected").addEventListener("click", async () => {
    state.snapshot.entries = state.snapshot.entries.map((item) => (item.id === entry.id ? deleteEntry(item) : item));
    state.selectedId = null;
    await persistSnapshot();
    renderVault();
  });
}

function openEntryDialog(entry = null) {
  state.editingId = entry?.id ?? null;
  elements.entryTitle.textContent = entry ? "Edit Entry" : "Add Entry";
  elements.entryLabel.value = entry?.label ?? "";
  elements.entryType.value = entry?.type ?? "credential";
  elements.entryUsername.value = entry?.payload.credential?.username ?? entry?.payload.server?.username ?? entry?.payload.service?.name ?? "";
  elements.entrySecret.value = entry?.payload.credential?.password ?? entry?.payload.server?.password ?? "";
  elements.entryCategory.value = entry?.payload.category ?? "";
  elements.entryTags.value = (entry?.payload.tags ?? []).join(", ");
  elements.entryNotes.value = entry?.payload.credential?.notes ?? entry?.payload.server?.notes ?? entry?.payload.service?.notes ?? "";
  elements.entryDialog.showModal();
}

function openSettingsDialog() {
  elements.requireTotp.checked = Boolean(state.snapshot.security?.requireTotp);
  elements.totpSecret.value = state.snapshot.security?.totpSecret ?? "";
  elements.syncProvider.value = state.syncSettings.providerType;
  elements.webdavUrl.value = state.syncSettings.webdavUrl;
  elements.webdavUsername.value = state.syncSettings.webdavUsername;
  elements.webdavPassword.value = state.syncSettings.webdavPassword;
  elements.webdavPath.value = state.syncSettings.webdavPath;
  elements.presignedDownloadUrl.value = state.syncSettings.presignedDownloadUrl;
  elements.presignedUploadUrl.value = state.syncSettings.presignedUploadUrl;
  elements.settingsDialog.showModal();
}

async function runBackup() {
  state.backups = createBackup(state.envelope, state.backups);
  writeJson(BACKUP_STORAGE_KEY, state.backups);
  state.snapshot.lastBackupStatus = `Backup saved: ${state.backups[0].name}`;
  await persistSnapshot();
  renderVault();
}

async function restoreLatestBackup() {
  if (!state.backups.length) return;
  state.envelope = state.backups[0].envelope;
  state.snapshot = await decryptVaultEnvelope(state.password, state.envelope);
  persistEnvelope();
  renderVault();
}

function downloadSnapshot() {
  const blob = new Blob([exportSnapshot(state.snapshot)], { type: "application/json" });
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = url;
  link.download = `vault-export-${new Date().toISOString().replace(/[:.]/g, "")}.json`;
  link.click();
  URL.revokeObjectURL(url);
}

async function syncNow() {
  if (state.syncSettings.providerType === "none") {
    state.snapshot.syncStatus = "Not configured";
    saveSyncSettings();
    await persistSnapshot();
    renderVault();
    return;
  }

  try {
    state.snapshot.syncStatus = "Syncing...";
    renderVault();
    const client = makeRemoteSyncClient(state.syncSettings);
    const result = await synchronizeSnapshot(state.snapshot, state.syncSettings, client);
    state.syncSettings = result.settings;
    state.snapshot = {
      ...result.snapshot,
      syncStatus: result.settings.lastSyncMessage
    };
  } catch (error) {
    const timestamp = new Date().toISOString();
    const message = error.message || "Sync failed.";
    state.syncSettings = {
      ...state.syncSettings,
      lastSyncAt: timestamp,
      lastSyncStatus: "failed",
      lastSyncMessage: message,
      logs: [{ timestamp, message, level: "error" }, ...(state.syncSettings.logs ?? [])].slice(0, 50)
    };
    state.snapshot.syncStatus = message;
  } finally {
    saveSyncSettings();
    await persistSnapshot();
    renderVault();
  }
}

async function persistSnapshot() {
  state.envelope = await createVaultEnvelope(state.password, state.snapshot, {
    iterations: state.envelope?.masterKeyRecord?.iterations
  });
  persistEnvelope();
}

function persistEnvelope() {
  writeJson(VAULT_STORAGE_KEY, state.envelope);
}

function loadSyncSettings() {
  const stored = readJson(SYNC_SETTINGS_KEY);
  if (!stored) return defaultSyncSettings();
  return applySyncSecrets(stored.settings, stored.secrets);
}

function saveSyncSettings() {
  writeJson(SYNC_SETTINGS_KEY, {
    settings: redactedSyncSettings(state.syncSettings),
    secrets: syncSecrets(state.syncSettings)
  });
}

function readJson(key) {
  const raw = localStorage.getItem(key);
  return raw ? JSON.parse(raw) : null;
}

function writeJson(key, value) {
  localStorage.setItem(key, JSON.stringify(value));
}

function registerServiceWorker() {
  if (!("serviceWorker" in navigator)) return;
  window.addEventListener("load", () => {
    navigator.serviceWorker.register("./sw.js").catch(() => {
      // Service worker registration is optional; the vault remains fully usable without it.
    });
  });
}

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}
