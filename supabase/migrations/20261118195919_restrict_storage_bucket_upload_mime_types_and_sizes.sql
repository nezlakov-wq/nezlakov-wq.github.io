-- Limit upload sizes and MIME types at the Storage API boundary.
-- Chat media is encrypted client-side, so only ciphertext is stored.
UPDATE storage.buckets
SET file_size_limit = 8388608,
    allowed_mime_types = ARRAY[
      'image/jpeg','image/png','image/webp','image/gif','image/avif',
      'video/mp4','video/webm','video/quicktime'
    ]
WHERE id = 'avatars';

UPDATE storage.buckets
SET file_size_limit = 20971520,
    allowed_mime_types = ARRAY[
      'image/jpeg','video/mp4','video/webm','video/quicktime'
    ]
WHERE id = 'story-media';

UPDATE storage.buckets
SET file_size_limit = 10485760,
    allowed_mime_types = ARRAY['application/octet-stream']
WHERE id = 'chat-media';
