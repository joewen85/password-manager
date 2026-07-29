import { FieldTemplate } from '../model/VaultTypes';

const TEXT_VALUE_TYPE: string = 'text';
const ENTRY_REFERENCE_VALUE_TYPE: string = 'entryReference';

export function isEditableCategoryFieldType(valueType: string | undefined): boolean {
  const normalized = normalizeValueType(valueType);
  return normalized === TEXT_VALUE_TYPE || normalized === ENTRY_REFERENCE_VALUE_TYPE;
}

export function categoryTemplateFieldChangePreservesStoredValueSemantics(
  existing: FieldTemplate,
  requested: FieldTemplate | null,
): boolean {
  if (requested === null || existing.id !== requested.id) {
    return false;
  }
  return normalizeValueType(existing.valueType) === normalizeValueType(requested.valueType);
}

export function categoryTemplateFieldsForUserSave(
  existing: FieldTemplate[],
  requestedCustomFields: FieldTemplate[],
  storedValueFieldIds: Set<string> = new Set<string>(),
): FieldTemplate[] {
  const requested = [
    baseField('template_名称', '名称'),
    baseField('template_备注', '备注'),
    ...requestedCustomFields.map((field: FieldTemplate) => cloneField(field)),
  ];
  const usedExistingIndexes = new Set<number>();
  const merged: FieldTemplate[] = [];

  requested.forEach((field: FieldTemplate) => {
    const existingIndex = matchingExistingFieldIndex(existing, field, usedExistingIndexes);
    if (existingIndex < 0) {
      merged.push(cloneField(field));
      return;
    }
    usedExistingIndexes.add(existingIndex);
    const current = existing[existingIndex];
    if (!isEditableCategoryFieldType(current.valueType)) {
      merged.push(cloneField(current));
      return;
    }
    if (
      storedValueFieldIds.has(current.id) &&
      !categoryTemplateFieldChangePreservesStoredValueSemantics(current, field)
    ) {
      merged.push(cloneField(current));
      return;
    }
    const mergedField: FieldTemplate = {
      id: current.id,
      name: field.name,
      valueType: normalizeValueType(field.valueType),
      targetCategory: normalizeTargetCategory(field),
    };
    const targetFieldId = preservedTargetFieldId(field, current);
    if (targetFieldId !== undefined) {
      mergedField.targetFieldId = targetFieldId;
    }
    merged.push(mergedField);
  });

  existing.forEach((field: FieldTemplate, index: number) => {
    if (usedExistingIndexes.has(index)) {
      return;
    }
    if (
      !isEditableCategoryFieldType(field.valueType) ||
      storedValueFieldIds.has(field.id)
    ) {
      merged.push(cloneField(field));
    }
  });
  return merged;
}

function matchingExistingFieldIndex(
  existing: FieldTemplate[],
  requested: FieldTemplate,
  usedIndexes: Set<number>,
): number {
  if (requested.id.trim().length > 0) {
    const idMatch = existing.findIndex(
      (field: FieldTemplate, index: number) =>
        !usedIndexes.has(index) && field.id === requested.id,
    );
    if (idMatch >= 0) {
      return idMatch;
    }
  }
  const name = requested.name.trim().toLowerCase();
  if (name.length === 0) {
    return -1;
  }
  return existing.findIndex(
    (field: FieldTemplate, index: number) =>
      !usedIndexes.has(index) && field.name.trim().toLowerCase() === name,
  );
}

function baseField(id: string, name: string): FieldTemplate {
  return {
    id,
    name,
    valueType: TEXT_VALUE_TYPE,
    targetCategory: '',
    targetFieldId: '',
  };
}

function cloneField(field: FieldTemplate): FieldTemplate {
  const cloned: FieldTemplate = {
    id: field.id,
    name: field.name,
    valueType: normalizeValueType(field.valueType),
    targetCategory: normalizeTargetCategory(field),
  };
  const targetFieldId = preservedTargetFieldId(field);
  if (targetFieldId !== undefined) {
    cloned.targetFieldId = targetFieldId;
  }
  return cloned;
}

function normalizeValueType(valueType: string | undefined): string {
  if (typeof valueType !== 'string' || valueType.trim().length === 0) {
    return TEXT_VALUE_TYPE;
  }
  return valueType;
}

function normalizeTargetCategory(field: FieldTemplate): string {
  const valueType = normalizeValueType(field.valueType);
  if (valueType === TEXT_VALUE_TYPE) {
    return '';
  }
  if (typeof field.targetCategory !== 'string') {
    return '';
  }
  return valueType === ENTRY_REFERENCE_VALUE_TYPE
    ? field.targetCategory.trim()
    : field.targetCategory;
}

function preservedTargetFieldId(
  field: FieldTemplate,
  fallback?: FieldTemplate,
): string | undefined {
  if (typeof field.targetFieldId === 'string') {
    return field.targetFieldId;
  }
  return typeof fallback?.targetFieldId === 'string'
    ? fallback.targetFieldId
    : undefined;
}
