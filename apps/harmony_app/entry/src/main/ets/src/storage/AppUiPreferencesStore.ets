import { preferences } from '@kit.ArkData';
import { Context } from '@kit.AbilityKit';
import {
  AppUiPreferences,
  defaultAppUiPreferences,
  normalizeAppAppearance,
  normalizeAppLanguage,
} from '../domain/AppUiPreferences';

export class AppUiPreferencesStore {
  private static readonly STORE_NAME: string = 'password_manager_app_ui_preferences';
  private static readonly LANGUAGE_KEY: string = 'language';
  private static readonly APPEARANCE_KEY: string = 'appearance';

  private readonly pref: preferences.Preferences;

  private constructor(pref: preferences.Preferences) {
    this.pref = pref;
  }

  static async create(context: Context): Promise<AppUiPreferencesStore> {
    const pref = await preferences.getPreferences(context, {
      name: AppUiPreferencesStore.STORE_NAME,
    });
    return new AppUiPreferencesStore(pref);
  }

  async read(): Promise<AppUiPreferences> {
    const defaults = defaultAppUiPreferences();
    return {
      language: normalizeAppLanguage(await this.pref.get(AppUiPreferencesStore.LANGUAGE_KEY, defaults.language) as string),
      appearance: normalizeAppAppearance(await this.pref.get(AppUiPreferencesStore.APPEARANCE_KEY, defaults.appearance) as string),
    };
  }

  async write(value: AppUiPreferences): Promise<void> {
    await this.pref.put(AppUiPreferencesStore.LANGUAGE_KEY, normalizeAppLanguage(value.language));
    await this.pref.put(AppUiPreferencesStore.APPEARANCE_KEY, normalizeAppAppearance(value.appearance));
    await this.pref.flush();
  }
}
