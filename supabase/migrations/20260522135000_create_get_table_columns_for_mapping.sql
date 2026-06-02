-- Create function to get table columns for admin mapping
CREATE OR REPLACE FUNCTION public.get_table_columns_for_mapping(table_names text[])
RETURNS TABLE(t_schema text, t_name text, c_name text)
LANGUAGE sql STABLE SECURITY DEFINER
AS $$
  SELECT 
    c.table_schema::text as t_schema, 
    c.table_name::text as t_name, 
    c.column_name::text as c_name
  FROM information_schema.columns c
  WHERE c.table_name = ANY(table_names)
    AND c.table_schema IN ('public', 'auth')
  ORDER BY c.table_schema, c.table_name, c.ordinal_position;
$$;

-- Grant execute permissions to standard roles
GRANT EXECUTE ON FUNCTION public.get_table_columns_for_mapping(text[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_table_columns_for_mapping(text[]) TO service_role;
