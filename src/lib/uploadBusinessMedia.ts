import { supabase } from '@/lib/supabase';
import { toUploadableFile } from '@/lib/uploadEventMedia';

// Logos and venue photos. The same limits are enforced by the storage bucket itself; checking them
// here first just gives the person a clear message instead of a storage error.
export const MAX_IMAGE_BYTES = 5 * 1024 * 1024;

const EXTENSION: Record<string, string> = {
  'image/jpeg': 'jpg',
  'image/png': 'png',
  'image/webp': 'webp',
};

/** A sentence describing what is wrong with the image, or null if it can be uploaded. */
export function imageProblem(file: { type: string; size: number }): string | null {
  if (!(file.type in EXTENSION)) return 'Use a JPEG, PNG or WebP image.';
  if (file.size > MAX_IMAGE_BYTES) return 'The image is larger than 5 MB. Choose a smaller one.';
  if (file.size === 0) return 'That file is empty.';
  return null;
}

/** The storage path: always inside the business's own folder, which is what the database policy checks. */
export function mediaPath(orgId: string, mimeType: string, id: string): string {
  return `${orgId}/${id}.${EXTENSION[mimeType] ?? 'jpg'}`;
}

/** Uploads an image for a business and returns its public address. iPhone HEIC photos are converted first. */
export async function uploadBusinessMedia(orgId: string, file: File): Promise<string> {
  let uploadable: File;
  try {
    uploadable = await toUploadableFile(file);
  } catch {
    throw new Error("Couldn't process this photo. Try a JPEG or PNG instead.");
  }
  const problem = imageProblem(uploadable);
  if (problem) throw new Error(problem);

  const path = mediaPath(orgId, uploadable.type, crypto.randomUUID());
  const { error } = await supabase.storage.from('business-media').upload(path, uploadable, {
    cacheControl: '31536000',
    upsert: false,
    contentType: uploadable.type,
  });
  if (error) throw new Error("The image could not be uploaded. You may not have access, or the file is not allowed.");
  return supabase.storage.from('business-media').getPublicUrl(path).data.publicUrl;
}
