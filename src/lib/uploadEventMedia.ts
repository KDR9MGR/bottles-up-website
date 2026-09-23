import { supabase } from '@/lib/supabase';

// iPhones default to HEIC for photos, which no mainstream browser can
// render in an <img> tag - a gallery/cover photo uploaded straight from a
// phone silently breaks for every visitor (found 2026-09-23: 4 of XNO
// Lounge's 5 gallery photos were HEIC and showed as broken image icons).
// Browsers can't decode HEIC themselves either, so this needs a real
// decoder - heic-to (libheif compiled to WASM) runs entirely client-side,
// before the file ever reaches Supabase storage. Tried heic2any first (the
// more commonly-referenced package) but its bundled libheif build couldn't
// decode one of the two real XNO Lounge files used to verify this
// (ERR_LIBHEIF format not supported) - heic-to's more recently-updated
// build handled both fine, confirmed live in the browser before switching.
async function toUploadableFile(file: File): Promise<File> {
  const { isHeic, heicTo } = await import('heic-to');
  if (!(await isHeic(file))) return file;

  const blob = await heicTo({ blob: file, type: 'image/jpeg', quality: 0.9 });
  const name = file.name.replace(/\.hei[cf]$/i, '.jpg');
  return new File([blob], name, { type: 'image/jpeg' });
}

export async function uploadEventMedia(file: File): Promise<string> {
  let uploadable: File;
  try {
    uploadable = await toUploadableFile(file);
  } catch (err) {
    // Deliberately not falling back to uploading the original HEIC here -
    // that would silently re-create the exact broken-photo bug this
    // conversion exists to prevent, just with no error to notice it by.
    console.error('uploadEventMedia: HEIC conversion failed', err);
    throw new Error("Couldn't process this photo. Try converting it to JPEG/PNG first, or use a different photo.");
  }

  const ext = uploadable.name.split('.').pop();
  const path = `${crypto.randomUUID()}.${ext}`;

  const { error } = await supabase.storage.from('event-media').upload(path, uploadable, {
    cacheControl: '31536000',
    upsert: false,
  });

  if (error) throw error;

  const { data } = supabase.storage.from('event-media').getPublicUrl(path);
  return data.publicUrl;
}
