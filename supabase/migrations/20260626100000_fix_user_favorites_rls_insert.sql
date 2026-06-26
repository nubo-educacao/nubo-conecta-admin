-- Fix RLS for user_favorites: add WITH CHECK so INSERT is allowed
-- FOR ALL USING without WITH CHECK blocks INSERT in Supabase
DROP POLICY IF EXISTS "Users can manage their own favorites" ON user_favorites;

-- Separate policies for clearer semantics
CREATE POLICY "Users can read their own favorites" ON user_favorites
  FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "Users can insert their own favorites" ON user_favorites
  FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can delete their own favorites" ON user_favorites
  FOR DELETE
  USING (auth.uid() = user_id);
