import { createClient } from '@supabase/supabase-js';
import type { Database } from './types';

const SUPABASE_URL = import.meta.env.VITE_SUPABASE_URL;
const SUPABASE_PUBLISHABLE_KEY = import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY;

if (!SUPABASE_URL || !SUPABASE_PUBLISHABLE_KEY) {
  console.error('Missing Supabase environment variables');
}

export const supabase = createClient<Database>(SUPABASE_URL || '', SUPABASE_PUBLISHABLE_KEY || '', {
  auth: {
    storage: localStorage,
    persistSession: true,
    autoRefreshToken: true,
  }
});

// Helper to create a client that doesn't persist session
// Useful for admin operations on the frontend (like creating users)
// without signing out the currently logged in admin.
export const createTempClient = () => createClient<Database>(SUPABASE_URL || '', SUPABASE_PUBLISHABLE_KEY || '', {
  auth: {
    persistSession: false,
  }
});
