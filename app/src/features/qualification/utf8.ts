/** Return false for JavaScript strings containing an unpaired surrogate. */
export function isUnicodeScalarString(value: string): boolean {
  for (let index = 0; index < value.length; index += 1) {
    const codeUnit = value.charCodeAt(index);
    if (codeUnit >= 0xd800 && codeUnit <= 0xdbff) {
      if (index + 1 >= value.length) return false;
      const next = value.charCodeAt(index + 1);
      if (next < 0xdc00 || next > 0xdfff) return false;
      index += 1;
    } else if (codeUnit >= 0xdc00 && codeUnit <= 0xdfff) {
      return false;
    }
  }
  return true;
}

/**
 * Small dependency-free scalar UTF-8 encoder used only to preserve the exact
 * reconstructed output bytes in qualification artifacts.
 */
export function encodeUtf8(value: string): readonly number[] {
  if (!isUnicodeScalarString(value)) {
    throw new Error('Cannot encode a string containing an unpaired surrogate.');
  }

  const bytes: number[] = [];
  for (const scalar of value) {
    const point = scalar.codePointAt(0);
    if (point === undefined) continue;
    if (point <= 0x7f) {
      bytes.push(point);
    } else if (point <= 0x7ff) {
      bytes.push(0xc0 | (point >> 6), 0x80 | (point & 0x3f));
    } else if (point <= 0xffff) {
      bytes.push(
        0xe0 | (point >> 12),
        0x80 | ((point >> 6) & 0x3f),
        0x80 | (point & 0x3f),
      );
    } else {
      bytes.push(
        0xf0 | (point >> 18),
        0x80 | ((point >> 12) & 0x3f),
        0x80 | ((point >> 6) & 0x3f),
        0x80 | (point & 0x3f),
      );
    }
  }
  return bytes;
}

export function utf8Hex(value: string): string {
  return encodeUtf8(value)
    .map((byte) => byte.toString(16).padStart(2, '0'))
    .join('');
}

export function unicodeScalarCount(value: string): number {
  if (!isUnicodeScalarString(value)) {
    throw new Error('Cannot count a string containing an unpaired surrogate.');
  }
  return [...value].length;
}
