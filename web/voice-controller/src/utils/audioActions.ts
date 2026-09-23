import type {AudioAction} from '@/types';

export function audioActionKey(action: AudioAction): string {
  return `${action.controllerIndex}:${action.category}:${action.index}`;
}

export function audioActionTypeName(action: AudioAction): string {
  const parts = String(action.typeName ?? '').split('.');
  return (parts[parts.length - 1] || '').replace(/^c(?=[A-Z])/, '');
}

export function audioActionLabel(
  action: AudioAction,
  _labels?: {controller: string; category: string; action: string},
): string {
  const typeName = audioActionTypeName(action);
  const identity = audioActionKey(action);
  return typeName ? `${typeName} (${identity})` : identity;
}
