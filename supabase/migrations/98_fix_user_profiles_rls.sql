-- Fix RLS policy for user_profiles to allow dependents creation

DROP POLICY IF EXISTS "Users can insert own profile" ON user_profiles;
CREATE POLICY "Users can insert own profile" ON user_profiles 
FOR INSERT 
WITH CHECK (
    auth.uid() = id -- User creating their own profile
    OR 
    auth.uid() = parent_user_id -- User creating a dependent profile
);

-- Similarly, update the update policy if needed
DROP POLICY IF EXISTS "Users can update own profile" ON user_profiles;
CREATE POLICY "Users can update own profile" ON user_profiles 
FOR UPDATE 
USING (
    auth.uid() = id 
    OR 
    auth.uid() = parent_user_id
);

-- And the select policy if dependents are going to be viewed by the parent
DROP POLICY IF EXISTS "Users can view own profile" ON user_profiles;
CREATE POLICY "Users can view own profile" ON user_profiles 
FOR SELECT 
USING (
    auth.uid() = id 
    OR 
    auth.uid() = parent_user_id
);
