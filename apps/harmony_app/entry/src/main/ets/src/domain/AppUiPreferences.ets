export type AppLanguagePreference = 'system' | 'english' | 'simplifiedChinese';
export type AppAppearancePreference = 'system' | 'light' | 'dark';

export interface AppUiPreferences {
  language: AppLanguagePreference;
  appearance: AppAppearancePreference;
}

export function defaultAppUiPreferences(): AppUiPreferences {
  return { language: 'system', appearance: 'system' };
}

export function normalizeAppLanguage(value: string): AppLanguagePreference {
  if (value === 'english' || value === 'simplifiedChinese') {
    return value;
  }
  return 'system';
}

export function normalizeAppAppearance(value: string): AppAppearancePreference {
  if (value === 'light' || value === 'dark') {
    return value;
  }
  return 'system';
}
