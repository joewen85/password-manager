export enum VaultEntryType {
  CREDENTIAL = 'credential',
  SERVER = 'server',
  SERVICE = 'service'
}

export interface CredentialPayload {
  username: string;
  password: string;
  token: string;
  appId: string;
  accessKey: string;
  secretKey: string;
  notes: string;
  tags: string[];
  category: string;
}

export interface ServerPayload {
  name: string;
  ipAddress: string;
  port: string;
  username: string;
  password: string;
  basicConfig: string;
  operatingSystem: string;
  location: string;
  notes: string;
  tags: string[];
  category: string;
}

export interface ServiceAccount {
  username: string;
  password: string;
  note: string;
}

export interface ServicePayload {
  name: string;
  connectionAddress: string;
  connectionPort: string;
  accountId: string;
  serverIds: string[];
  accounts: ServiceAccount[];
  notes: string;
  tags: string[];
  category: string;
}

export type VaultPayload = CredentialPayload | ServerPayload | ServicePayload;

export interface CustomField {
  id: string;
  name: string;
  value: string;
}

export interface VaultEntry {
  id: string;
  label: string;
  type: VaultEntryType;
  payload: VaultPayload;
  tags: string[];
  customFields: CustomField[];
  createdAt: number;
  updatedAt: number;
  isDeleted: boolean;
}

export interface MasterKeyRecord {
  saltBase64: string;
  iterations: number;
  verifierBase64: string;
  metadataSaltBase64?: string;
  metadataIterations?: number;
}

export interface VaultSnapshot {
  masterKeyRecord: MasterKeyRecord | null;
  tags: string[];
  categories: string[];
  entries: VaultEntry[];
  updatedAt: number;
}

export interface EncryptedPayloadRecord {
  ciphertext: string;
  nonce: string;
  mac: string;
  version: number;
}

export interface VaultPayloadRecord {
  tags: string[];
  categories: string[];
  entries: VaultEntry[];
  security?: SecuritySettings;
  updatedAt: number;
}

export interface VaultPersistenceEnvelope {
  schemaVersion: number;
  masterKeyRecord: MasterKeyRecord | null;
  encryptedVault: EncryptedPayloadRecord | null;
  unlockGuard?: UnlockGuardState;
  updatedAt: number;
}

export interface SecuritySettings {
  requireTotp: boolean;
  totpSecret: string;
  biometricUnlockEnabled?: boolean;
  idleAutoLockMinutes?: number;
}

export interface UnlockGuardState {
  failedAttempts: number;
  lockUntil: number;
}

export interface CreateCredentialInput {
  label: string;
  username: string;
  password: string;
  token: string;
  appId: string;
  accessKey: string;
  secretKey: string;
  notes: string;
  tags: string[];
  category: string;
  customFields?: CustomField[];
}

export interface CreateServerInput {
  label: string;
  name: string;
  ipAddress: string;
  port: string;
  username: string;
  password: string;
  basicConfig: string;
  operatingSystem: string;
  location: string;
  notes: string;
  tags: string[];
  category: string;
  customFields?: CustomField[];
}

export interface CreateServiceInput {
  label: string;
  name: string;
  connectionAddress: string;
  connectionPort: string;
  accountId: string;
  serverIds: string[];
  accounts: ServiceAccount[];
  notes: string;
  tags: string[];
  category: string;
  customFields?: CustomField[];
}
