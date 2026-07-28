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

function matchingEntryReferenceTemplate(
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
  if (template === undefined || template.valueType !== 'entryReference') {
    return null;
  }
  return template;
}
