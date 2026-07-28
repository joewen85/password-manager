import {
  CategoryTemplate,
  CustomField,
  VaultEntry,
} from '../model/VaultTypes';
import {
  EntryReferenceStatus,
  matchingEntryReferenceTemplate,
  resolveEntryReference,
} from './FieldReferenceResolver';

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
      resolution === null ||
      resolution.status !== EntryReferenceStatus.RESOLVED ||
      resolution.target === undefined
    ) {
      return;
    }
    appendSearchValue(values, seen, resolution.target.label);
    appendSearchValue(values, seen, resolution.target.category);
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
    if (matchingEntryReferenceTemplate(field, template) === null) {
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
