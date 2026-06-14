import json
import sys
import os

input_file = r'C:\Users\Bruno Bogochvol\.gemini\antigravity-ide\brain\493d9d1e-ed32-4de3-a701-00f8a09431a5\.system_generated\steps\5063\output.txt'
base_output_file = r'C:\Users\Bruno Bogochvol\Documents\GitHub\Nubo\nubo-conecta-admin\insert_rawemec_parte'

with open(input_file, 'r', encoding='utf-8') as f:
    data = json.load(f)

if not data:
    print('No data found')
    sys.exit(1)

columns = list(data[0].keys())
quoted_cols = ', '.join([f'"{c}"' for c in columns])

batch_size = 500
file_count = 1

# First file: truncate
with open(f'{base_output_file}_{file_count}.sql', 'w', encoding='utf-8') as out:
    out.write('BEGIN;\nTRUNCATE TABLE public.rawemec;\nCOMMIT;\n')
file_count += 1

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
        
    with open(f'{base_output_file}_{file_count}.sql', 'w', encoding='utf-8') as out:
        out.write('BEGIN;\n')
        out.write(f'INSERT INTO public.rawemec ({quoted_cols}) VALUES\n')
        out.write(',\n'.join(values_lines) + ';\n\n')
        out.write('COMMIT;\n')
    
    print(f'Created {base_output_file}_{file_count}.sql')
    file_count += 1

print(f'Total {file_count-1} files generated.')
