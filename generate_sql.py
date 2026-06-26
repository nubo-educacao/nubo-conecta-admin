import json
import sys
import os

input_file = r'C:\Users\Bruno Bogochvol\.gemini\antigravity-ide\brain\493d9d1e-ed32-4de3-a701-00f8a09431a5\.system_generated\steps\5063\output.txt'
output_file = r'C:\Users\Bruno Bogochvol\Documents\GitHub\Nubo\nubo-conecta-admin\insert_rawemec.sql'

with open(input_file, 'r', encoding='utf-8') as f:
    data = json.load(f)

if not data:
    print('No data found')
    sys.exit(1)

columns = list(data[0].keys())
quoted_cols = ', '.join([f'"{c}"' for c in columns])

with open(output_file, 'w', encoding='utf-8') as out:
    out.write('BEGIN;\n')
    out.write('TRUNCATE TABLE public.rawemec;\n\n')
    
    batch_size = 500
    for i in range(0, len(data), batch_size):
        batch = data[i:i+batch_size]
        
        values_lines = []
        for row in batch:
            vals = []
            for col in columns:
                val = row.get(col)
                if val is None:
                    vals.append('NULL')
                else:
                    escaped_val = str(val).replace("'", "''")
                    vals.append(f"'{escaped_val}'")
            values_lines.append('(' + ', '.join(vals) + ')')
            
        out.write(f'INSERT INTO public.rawemec ({quoted_cols}) VALUES\n')
        out.write(',\n'.join(values_lines) + ';\n\n')
        
    out.write('COMMIT;\n')

print(f'SQL file generated successfully with {len(data)} rows at {output_file}')
