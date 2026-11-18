-- pg_net is non-relocatable; recreate it with its extension metadata in the
-- dedicated extensions schema. The net schema and API objects are recreated by
-- the extension script. The request queue was verified empty before this change.
DROP EXTENSION pg_net;
CREATE EXTENSION pg_net WITH SCHEMA extensions;
