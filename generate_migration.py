import re

with open('supabase/migrations/20260605174000_richer_all_etl_success_logs.sql', 'r', encoding='utf-8') as f:
    content = f.read()

def inject_truncate(func_name, raw_table):
    # Match CREATE OR REPLACE FUNCTION public.func_name(...) ... END; $$;
    pattern = r"CREATE OR REPLACE FUNCTION public\." + func_name + r"[\s\S]*?(?:\$\$|\$function\$);"
    match = re.search(pattern, content)
    if not match:
        raise Exception(f"Function {func_name} not found")
    func_code = match.group(0)
    
    # Inject TRUNCATE before RETURN jsonb_build_object
    replacement = (
        "WHERE id = v_log_id;\n\n"
        f"    -- Clear raw table to free space and prevent accidental re-runs\n"
        f"    TRUNCATE TABLE public.{raw_table};\n"
        "  END IF;\n\n"
        "  RETURN jsonb_build_object("
    )
    
    new_func_code = re.sub(
        r"WHERE id = v_log_id;\s+END IF;\s+RETURN jsonb_build_object\(",
        replacement,
        func_code
    )
    return new_func_code

funcs = [
    ('etl_import_prouni_base', 'rawprouni'),
    ('etl_import_prouni_vacancies', 'rawprounivacancies'),
    ('etl_import_prouni_occupied', 'rawprounioccupied'),
    ('etl_import_emec', 'rawemec')
]

migration = "-- Truncate raw tables on successful ETL runs for ProUni and e-MEC\n-- 20260605191500_truncate_raw_tables_prouni_emec.sql\n\n"
for func, table in funcs:
    migration += inject_truncate(func, table) + "\n\n"

with open('supabase/migrations/20260605191500_truncate_raw_tables_prouni_emec.sql', 'w', encoding='utf-8') as f:
    f.write(migration)
