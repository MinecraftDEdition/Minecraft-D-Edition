export type SkinModel = 'classic' | 'slim';

export function normalizeSkinModel(value: unknown): SkinModel | null {
  return value === 'classic' || value === 'slim' ? value : null;
}
