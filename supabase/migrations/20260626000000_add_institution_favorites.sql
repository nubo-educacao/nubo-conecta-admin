-- Add institution_id to user_favorites and fix RLS policies
ALTER TABLE user_favorites ADD COLUMN IF NOT EXISTS institution_id uuid REFERENCES institutions(id) ON DELETE CASCADE;

-- Update the check constraint to allow institution_id
ALTER TABLE user_favorites DROP CONSTRAINT IF EXISTS user_favorites_target_check;
ALTER TABLE user_favorites ADD CONSTRAINT user_favorites_target_check CHECK (
    (course_id IS NOT NULL AND partner_opportunities_id IS NULL AND institution_id IS NULL) OR
    (course_id IS NULL AND partner_opportunities_id IS NOT NULL AND institution_id IS NULL) OR
    (course_id IS NULL AND partner_opportunities_id IS NULL AND institution_id IS NOT NULL)
);

-- Fix RLS policy for user_favorites
DROP POLICY IF EXISTS "Users can manage their own favorites" ON user_favorites;
CREATE POLICY "Users can manage their own favorites" ON user_favorites
  FOR ALL
  USING (auth.uid() = user_id OR user_id IN (SELECT current_dependent_id FROM user_profiles WHERE id = auth.uid()));
