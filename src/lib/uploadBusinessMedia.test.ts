import { describe, expect, it } from 'vitest';
import { imageProblem, MAX_IMAGE_BYTES, mediaPath } from './uploadBusinessMedia';

describe('imageProblem', () => {
  it.each(['image/jpeg', 'image/png', 'image/webp'])('accepts %s', (type) => {
    expect(imageProblem({ type, size: 1000 })).toBeNull();
  });

  it.each(['image/gif', 'image/heic', 'image/svg+xml', 'application/pdf', 'text/html', ''])('rejects %j', (type) => {
    expect(imageProblem({ type, size: 1000 })).toMatch(/JPEG, PNG or WebP/);
  });

  it('allows exactly the size limit and refuses one byte over', () => {
    expect(imageProblem({ type: 'image/png', size: MAX_IMAGE_BYTES })).toBeNull();
    expect(imageProblem({ type: 'image/png', size: MAX_IMAGE_BYTES + 1 })).toMatch(/5 MB/);
  });

  it('refuses an empty file', () => {
    expect(imageProblem({ type: 'image/png', size: 0 })).toMatch(/empty/);
  });

  it('SVG is refused: it can carry script and is served from a public bucket', () => {
    expect(imageProblem({ type: 'image/svg+xml', size: 100 })).not.toBeNull();
  });
});

describe('mediaPath', () => {
  const org = '11111111-2222-3333-4444-555555555555';
  it('puts the file in the business folder with an extension from the real type, not the file name', () => {
    expect(mediaPath(org, 'image/png', 'abc')).toBe(`${org}/abc.png`);
    expect(mediaPath(org, 'image/jpeg', 'abc')).toBe(`${org}/abc.jpg`);
    expect(mediaPath(org, 'image/webp', 'abc')).toBe(`${org}/abc.webp`);
  });

  it('the first folder is always the organization id (what the database policy checks)', () => {
    expect(mediaPath(org, 'image/png', 'x').split('/')[0]).toBe(org);
  });
});
