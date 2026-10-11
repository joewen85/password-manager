import {
  CategoryTemplate,
  CustomField,
  FieldTemplate,
  VaultEntry,
} from '../model/VaultTypes';

export enum EntryReferenceStatus {
  EMPTY = 'EMPTY',
  RESOLVED = 'RESOLVED',
  MISSING = 'MISSING',
  DELETED = 'DELETED',
  CATEGORY_MISMATCH = 'CATEGORY_MISMATCH',
}

export interface EntryReferenceTarget {
  id: string;
  label: string;
  category: string;
}

export interface EntryReferenceResolution {
  status: EntryReferenceStatus;
  target?: EntryReferenceTarget;
}

export enum FieldValueReferenceStatus {
  EMPTY = 'EMPTY',
  INVALID_CONFIGURATION = 'INVALID_CONFIGURATION',
  MISSING = 'MISSING',
  DELETED = 'DELETED',
  CATEGORY_MISMATCH = 'CATEGORY_MISMATCH',
  TARGET_FIELD_MISSING = 'TARGET_FIELD_MISSING',
  TARGET_FIELD_UNSUPPORTED = 'TARGET_FIELD_UNSUPPORTED',
  TARGET_FIELD_EMPTY = 'TARGET_FIELD_EMPTY',
  RESOLVED = 'RESOLVED',
}

export interface FieldValueReferenceTarget {
  id: string;
  label: string;
  category: string;
  fieldId: string;
  fieldName: string;
  value: string;
}

export interface FieldValueReferenceResolution {
  status: FieldValueReferenceStatus;
  target?: FieldValueReferenceTarget;
}

export function propagateEntryReferenceCategoryRename(
  templates: CategoryTemplate[],
  oldCategory: string,
  newCategory: string,
): CategoryTemplate[] {
  const oldNormalized = oldCategory.trim();
  const newNormalized = newCategory.trim();
  if (oldNormalized.length === 0 || newNormalized.length === 0) {
    return templates;
  }
  const oldKey = oldNormalized.toLowerCase();
  return templates.map((template: CategoryTemplate) => {
    let changed = false;
    const fields = template.fields.map((field: FieldTemplate) => {
      const targetCategory = field.targetCategory?.trim() ?? '';
      if (
        (field.valueType !== 'entryReference' && field.valueType !== 'fieldReference') ||
        targetCategory.toLowerCase() !== oldKey
      ) {
        return field;
      }
      changed = true;
      return {
        id: field.id,
        name: field.name,
        valueType: field.valueType,
        targetCategory: newNormalized,
        targetFieldId: field.targetFieldId,
      };
    });
    if (!changed) {
      return template;
    }
    return {
      category: template.category,
      fields,
    };
  });
}

export function resolveFieldValueReference(
  sourceEntry: VaultEntry,
  field: CustomField,
  templates: CategoryTemplate[],
  entries: VaultEntry[],
): FieldValueReferenceResolution | null {
  const sourceTemplate = categoryTemplateFor(templates, sourceEntry.payload.category);
  const templateField = matchingFieldValueReferenceTemplate(field, sourceTemplate);
  if (templateField === null) {
    return null;
  }
  if (field.value.trim().length === 0) {
    return { status: FieldValueReferenceStatus.EMPTY };
  }

  const targetCategory = templateField.targetCategory?.trim() ?? '';
  const targetFieldId = templateField.targetFieldId ?? '';
  if (targetCategory.length === 0 || targetFieldId.trim().length === 0) {
    return { status: FieldValueReferenceStatus.INVALID_CONFIGURATION };
  }
  if (
    sourceTemplate !== null &&
    sourceTemplate.category.trim().toLowerCase() === targetCategory.toLowerCase() &&
    templateField.id === targetFieldId
  ) {
    return { status: FieldValueReferenceStatus.INVALID_CONFIGURATION };
  }

  const targetEntry = entries.find((entry: VaultEntry) => entry.id === field.value);
  if (targetEntry === undefined) {
    return { status: FieldValueReferenceStatus.MISSING };
  }
  const target: FieldValueReferenceTarget = {
    id: targetEntry.id,
    label: targetEntry.label,
    category: targetEntry.payload.category.trim(),
    fieldId: targetFieldId,
    fieldName: '',
    value: '',
  };
  if (targetEntry.isDeleted) {
    return { status: FieldValueReferenceStatus.DELETED, target };
  }
  if (target.category.toLowerCase() !== targetCategory.toLowerCase()) {
    return { status: FieldValueReferenceStatus.CATEGORY_MISMATCH, target };
  }

  const targetTemplate = categoryTemplateFor(templates, target.category);
  const targetFieldTemplate = targetTemplate?.fields.find(
    (candidate: FieldTemplate) => candidate.id === targetFieldId,
  );
  if (targetFieldTemplate === undefined) {
    return { status: FieldValueReferenceStatus.TARGET_FIELD_MISSING, target };
  }
  target.fieldName = targetFieldTemplate.name;
  if (normalizedValueType(targetFieldTemplate.valueType) !== 'text') {
    return { status: FieldValueReferenceStatus.TARGET_FIELD_UNSUPPORTED, target };
  }
  if (isBuiltInEntryNameField(targetFieldTemplate)) {
    if (targetEntry.label.trim().length === 0) {
      return { status: FieldValueReferenceStatus.TARGET_FIELD_EMPTY, target };
    }
    target.value = targetEntry.label;
    return { status: FieldValueReferenceStatus.RESOLVED, target };
  }
  const targetValue = matchingTargetCustomField(
    targetEntry.customFields,
    targetFieldTemplate,
  );
  if (targetValue === undefined || targetValue.value.trim().length === 0) {
    return { status: FieldValueReferenceStatus.TARGET_FIELD_EMPTY, target };
  }
  target.value = targetValue.value;
  return { status: FieldValueReferenceStatus.RESOLVED, target };
}

export function matchingFieldValueReferenceTemplate(
  field: CustomField,
  categoryTemplate: CategoryTemplate | null,
): FieldTemplate | null {
  const template = matchingTemplateField(field, categoryTemplate);
  return template?.valueType === 'fieldReference' ? template : null;
}

export function targetFieldReferenceIdsForCategory(
  templates: CategoryTemplate[],
  targetCategory: string,
): Set<string> {
  const categoryKey = targetCategory.trim().toLowerCase();
  const ids = new Set<string>();
  if (categoryKey.length === 0) {
    return ids;
  }
  templates.forEach((template: CategoryTemplate) => {
    template.fields.forEach((field: FieldTemplate) => {
      const configuredCategory = field.targetCategory?.trim().toLowerCase() ?? '';
      const targetFieldId = field.targetFieldId ?? '';
      if (
        field.valueType === 'fieldReference' &&
        configuredCategory === categoryKey &&
        targetFieldId.trim().length > 0
      ) {
        ids.add(targetFieldId);
      }
    });
  });
  return ids;
}

export function resolveEntryReference(
  field: CustomField,
  template: CategoryTemplate | null,
  entries: VaultEntry[],
): EntryReferenceResolution | null {
  const templateField = matchingEntryReferenceTemplate(field, template);
  if (templateField === null) {
    return null;
  }
  if (field.value.trim().length === 0) {
    return { status: EntryReferenceStatus.EMPTY };
  }

  const target = entries.find((entry: VaultEntry) => entry.id === field.value);
  if (target === undefined) {
    return { status: EntryReferenceStatus.MISSING };
  }
  const actualCategory = target.payload.category.trim();
  const projection: EntryReferenceTarget = {
    id: target.id,
    label: target.label,
    category: actualCategory,
  };
  if (target.isDeleted) {
    return {
      status: EntryReferenceStatus.DELETED,
      target: projection,
    };
  }

  const targetCategory = templateField.targetCategory?.trim() ?? '';
  if (
    targetCategory.length > 0 &&
    targetCategory.toLowerCase() !== actualCategory.toLowerCase()
  ) {
    return {
      status: EntryReferenceStatus.CATEGORY_MISMATCH,
      target: projection,
    };
  }

  return {
    status: EntryReferenceStatus.RESOLVED,
    target: projection,
  };
}

export function matchingEntryReferenceTemplate(
  field: CustomField,
  categoryTemplate: CategoryTemplate | null,
): FieldTemplate | null {
  const template = matchingTemplateField(field, categoryTemplate);
  return template?.valueType === 'entryReference' ? template : null;
}

function matchingTemplateField(
  field: CustomField,
  categoryTemplate: CategoryTemplate | null,
): FieldTemplate | null {
  const templateFields = categoryTemplate?.fields;
  if (templateFields === undefined) {
    return null;
  }
  let template: FieldTemplate | undefined;
  if (
    typeof field.templateFieldId === 'string' &&
    field.templateFieldId.length > 0
  ) {
    template = templateFields.find(
      (candidate: FieldTemplate) => candidate.id === field.templateFieldId,
    );
  } else {
    const fieldName = field.name.trim().toLowerCase();
    if (fieldName.length > 0) {
      template = templateFields.find(
        (candidate: FieldTemplate) => candidate.name.trim().toLowerCase() === fieldName,
      );
    }
  }
  return template ?? null;
}

function matchingTargetCustomField(
  fields: CustomField[],
  targetFieldTemplate: FieldTemplate,
): CustomField | undefined {
  const exactMatch = fields.find((candidate: CustomField) =>
    typeof candidate.templateFieldId === 'string' &&
      candidate.templateFieldId.length > 0 &&
      candidate.templateFieldId === targetFieldTemplate.id
  );
  if (exactMatch !== undefined) {
    return exactMatch;
  }

  const targetName = targetFieldTemplate.name.trim().toLowerCase();
  if (targetName.length === 0) {
    return undefined;
  }
  return fields.find((candidate: CustomField) =>
    (typeof candidate.templateFieldId !== 'string' ||
      candidate.templateFieldId.length === 0) &&
      candidate.name.trim().toLowerCase() === targetName
  );
}

function isBuiltInEntryNameField(field: FieldTemplate): boolean {
  return field.id === 'template_名称' || field.name.trim() === '名称';
}

function categoryTemplateFor(
  templates: CategoryTemplate[],
  category: string,
): CategoryTemplate | null {
  const key = category.trim().toLowerCase();
  if (key.length === 0) {
    return null;
  }
  return templates.find(
    (template: CategoryTemplate) => template.category.trim().toLowerCase() === key,
  ) ?? null;
}

function normalizedValueType(valueType: string | undefined): string {
  if (typeof valueType !== 'string' || valueType.trim().length === 0) {
    return 'text';
  }
  return valueType;
}
