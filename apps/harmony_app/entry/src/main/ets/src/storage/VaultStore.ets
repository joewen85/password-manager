import { preferences } from '@kit.ArkData';
import { Context } from '@kit.AbilityKit';
import { VaultPersistenceEnvelope } from '../model/VaultTypes';

export interface VaultStore {
  readEnvelope(): Promise<VaultPersistenceEnvelope | null>;
  writeEnvelope(envelope: VaultPersistenceEnvelope): Promise<void>;
}

export class InMemoryVaultStore implements VaultStore {
  private envelope: VaultPersistenceEnvelope | null = null;

  async readEnvelope(): Promise<VaultPersistenceEnvelope | null> {
    if (this.envelope === null) {
      return null;
    }
    return deepCopyEnvelope(this.envelope);
  }

  async writeEnvelope(envelope: VaultPersistenceEnvelope): Promise<void> {
    this.envelope = deepCopyEnvelope(envelope);
  }
}

export class PreferencesVaultStore implements VaultStore {
  private static readonly STORE_NAME: string = 'password_manager_secure_store';
  private static readonly ENVELOPE_KEY: string = 'vault_envelope';

  private readonly pref: preferences.Preferences;

  private constructor(pref: preferences.Preferences) {
    this.pref = pref;
  }

  static async create(context: Context): Promise<PreferencesVaultStore> {
    const options: preferences.Options = {
      name: PreferencesVaultStore.STORE_NAME
    };
    try {
      const pref = await preferences.getPreferences(context, options);
      return new PreferencesVaultStore(pref);
    } catch (error) {
      throw new Error(`Open preferences failed: ${error}`);
    }
  }

  async readEnvelope(): Promise<VaultPersistenceEnvelope | null> {
    try {
      const raw = await this.pref.get(
        PreferencesVaultStore.ENVELOPE_KEY,
        ''
      ) as string;
      if (raw.trim().length === 0) {
        return null;
      }
      const parsed = JSON.parse(raw) as VaultPersistenceEnvelope;
      return deepCopyEnvelope(parsed);
    } catch (error) {
      throw new Error(`Read preferences envelope failed: ${error}`);
    }
  }

  async writeEnvelope(envelope: VaultPersistenceEnvelope): Promise<void> {
    try {
      await this.pref.put(
        PreferencesVaultStore.ENVELOPE_KEY,
        JSON.stringify(envelope)
      );
      await this.pref.flush();
    } catch (error) {
      throw new Error(`Write preferences envelope failed: ${error}`);
    }
  }
}

function deepCopyEnvelope(
  envelope: VaultPersistenceEnvelope,
): VaultPersistenceEnvelope {
  return JSON.parse(JSON.stringify(envelope)) as VaultPersistenceEnvelope;
}
