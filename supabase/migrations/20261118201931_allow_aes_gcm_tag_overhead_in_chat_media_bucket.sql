-- AES-GCM ciphertext adds a 16-byte authentication tag to the uploaded file.
-- Allow that tag when the client accepts a plaintext file up to 10 MiB.
UPDATE storage.buckets
SET file_size_limit = 10485776
WHERE id = 'chat-media';
