-- Fix _eligib_to_num to correctly parse Brazilian currency strings like 'R$ 3.258,21' and US decimals like '4500.00'

CREATE OR REPLACE FUNCTION public._eligib_to_num(p_text text)
RETURNS numeric
LANGUAGE sql IMMUTABLE
AS $$
    SELECT NULLIF(
        CASE 
            WHEN p_text LIKE '%,%' THEN 
                regexp_replace(
                    replace(replace(btrim(p_text), '.', ''), ',', '.'),
                    '[^0-9.-]', '', 'g'
                )
            ELSE 
                regexp_replace(btrim(p_text), '[^0-9.-]', '', 'g')
        END,
        ''
    )::numeric;
$$;

COMMENT ON FUNCTION public._eligib_to_num(text) IS
'Extrai numérico de strings sujas usadas em partner_forms.criterion_rule (ex.: "17 anos", "R$ 3.258,21", "4500.00"). Reconhece padrão BR se houver vírgula, e padrão US se houver apenas ponto.';
