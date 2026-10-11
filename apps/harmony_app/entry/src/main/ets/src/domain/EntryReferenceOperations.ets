import {
  CategoryTemplate,
  CustomField,
  FieldTemplate,
  VaultEntry,
} from '../model/VaultTypes';
import {
  EntryReferenceStatus,
  FieldValueReferenceStatus,
  matchingEntryReferenceTemplate,
  matchingFieldValueReferenceTemplate,
  resolveEntryReference,
  resolveFieldValueReference,
} from './FieldReferenceResolver';

export interface EntryReferenceCandidate {
  id: string;
  label: string;
  category: string;
}

const CUSTOM_FIELD_TEXT_VALUE_TYPE: string = 'text';
const CUSTOM_FIELD_ENTRY_REFERENCE_VALUE_TYPE: string = 'entryReference';

export function resolvedEntryReferenceSearchValues(
  entry: VaultEntry,
  templates: CategoryTemplate[],
  entries: VaultEntry[],
): string[] {
  const template = categoryTemplateFor(templates, entry.payload.category);
  const values: string[] = [];
  const seen = new Set<string>();
  entry.customFields.forEach((field: CustomField) => {
    const resolution = resolveEntryReference(field, template, entries);
    if (
      resolution !== null &&
      resolution.status === EntryReferenceStatus.RESOLVED &&
      resolution.target !== undefined
    ) {
      appendSearchValue(values, seen, resolution.target.label);
      appendSearchValue(values, seen, resolution.target.category);
    }
    const fieldResolution = resolveFieldValueReference(entry, field, templates, entries);
    if (
      fieldResolution !== null &&
      fieldResolution.status === FieldValueReferenceStatus.RESOLVED &&
      fieldResolution.target !== undefined
    ) {
      appendSearchValue(values, seen, fieldResolution.target.label);
      appendSearchValue(values, seen, fieldResolution.target.category);
      appendSearchValue(values, seen, fieldResolution.target.fieldName);
    }
  });
  return values;
}

export function remapEntryReferenceCustomFields(
  fields: CustomField[],
  category: string,
  templates: CategoryTemplate[],
  idMap: Map<string, string>,
): CustomField[] {
  const template = categoryTemplateFor(templates, category);
  return fields.map((field: CustomField) => {
    if (
      matchingEntryReferenceTemplate(field, template) === null &&
      matchingFieldValueReferenceTemplate(field, template) === null
    ) {
      return field;
    }
    const mappedId = idMap.get(field.value);
    if (mappedId === undefined || mappedId === field.value) {
      return field;
    }
    return {
      id: field.id,
      name: field.name,
      value: mappedId,
      templateFieldId: field.templateFieldId,
    };
  });
}

export function entryReferenceCandidates(
  entries: VaultEntry[],
  targetCategory: string,
  query: string,
): EntryReferenceCandidate[] {
  const categoryKey = targetCategory.trim().toLowerCase();
  const queryKey = query.trim().toLowerCase();
  return entries
    .filter((entry: VaultEntry) => !entry.isDeleted)
    .filter((entry: VaultEntry) =>
      categoryKey.length === 0 || entry.payload.category.trim().toLowerCase() === categoryKey
    )
    .filter((entry: VaultEntry) => {
      if (queryKey.length === 0) {
        return true;
      }
      return entry.label.toLowerCase().includes(queryKey) ||
        entry.payload.category.trim().toLowerCase().includes(queryKey);
    })
    .sort((left: VaultEntry, right: VaultEntry) => {
      const labelOrder = left.label.localeCompare(right.label);
      return labelOrder !== 0 ? labelOrder : left.id.localeCompare(right.id);
    })
    .map((entry: VaultEntry) => {
      const candidate: EntryReferenceCandidate = {
        id: entry.id,
        label: entry.label,
        category: entry.payload.category.trim(),
      };
      return candidate;
    });
}

export function safeCustomFieldSearchValues(
  field: CustomField,
  template: CategoryTemplate | null,
  entries: VaultEntry[],
): string[] {
  const fieldTemplate = matchingCustomFieldTemplate(field, template);
  if (fieldTemplate === null) {
    return hasBoundTemplateFieldId(field)
      ? compactSearchValues([field.name])
      : compactSearchValues([field.name, field.value]);
  }
  const valueType = normalizedTemplateValueType(fieldTemplate.valueType);
  if (valueType === CUSTOM_FIELD_TEXT_VALUE_TYPE) {
    return compactSearchValues([field.name, field.value]);
  }
  if (valueType !== CUSTOM_FIELD_ENTRY_REFERENCE_VALUE_TYPE) {
    return compactSearchValues([field.name]);
  }
  const resolution = resolveEntryReference(field, template, entries);
  if (
    resolution === null ||
    resolution.status !== EntryReferenceStatus.RESOLVED ||
    resolution.target === undefined
  ) {
    return [field.name];
  }
  return compactSearchValues([
    field.name,
    resolution.target.label,
    resolution.target.category,
  ]);
}

export function canExposeRawCustomFieldValue(
  field: CustomField,
  template: CategoryTemplate | null,
): boolean {
  const fieldTemplate = matchingCustomFieldTemplate(field, template);
  if (fieldTemplate === null) {
    return !hasBoundTemplateFieldId(field);
  }
  return normalizedTemplateValueType(fieldTemplate.valueType) === CUSTOM_FIELD_TEXT_VALUE_TYPE;
}

export function entryReferenceTemplateForField(
  field: CustomField,
  template: CategoryTemplate | null,
): FieldTemplate | null {
  return matchingEntryReferenceTemplate(field, template);
}

function matchingCustomFieldTemplate(
  field: CustomField,
  template: CategoryTemplate | null,
): FieldTemplate | null {
  const fields = template?.fields;
  if (fields === undefined) {
    return null;
  }
  if (hasBoundTemplateFieldId(field)) {
    return fields.find(
      (candidate: FieldTemplate) => candidate.id === field.templateFieldId,
    ) ?? null;
  }
  const name = field.name.trim().toLowerCase();
  if (name.length === 0) {
    return null;
  }
  return fields.find(
    (candidate: FieldTemplate) => candidate.name.trim().toLowerCase() === name,
  ) ?? null;
}

function hasBoundTemplateFieldId(field: CustomField): boolean {
  return typeof field.templateFieldId === 'string' && field.templateFieldId.length > 0;
}

function normalizedTemplateValueType(valueType: string | undefined): string {
  if (typeof valueType !== 'string' || valueType.trim().length === 0) {
    return CUSTOM_FIELD_TEXT_VALUE_TYPE;
  }
  return valueType;
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

function appendSearchValue(values: string[], seen: Set<string>, value: string): void {
  const normalized = value.trim();
  if (normalized.length === 0 || seen.has(normalized)) {
    return;
  }
  seen.add(normalized);
  values.push(normalized);
}

function compactSearchValues(source: string[]): string[] {
  const values: string[] = [];
  const seen = new Set<string>();
  source.forEach((value: string) => appendSearchValue(values, seen, value));
  return values;
}
