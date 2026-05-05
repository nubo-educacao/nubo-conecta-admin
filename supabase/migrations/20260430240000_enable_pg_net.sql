-- Migration: Enable pg_net extension for async HTTP requests
-- Required by trigger_match_calculation() which uses net.http_post()

CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;
