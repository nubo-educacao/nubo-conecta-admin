# Match Engine — Deep Dive

> Versão: V3 Funnel+Cap | Sprint 10
> Função: `public.calculate_match(p_profile_id UUID)`
> Acionamento: Edge Function `calculate-match-v3` via trigger `pg_net`

---

## 1. Visão Geral

O Match Engine é um **sistema de ranking personalizado** que, dado um perfil de usuário, seleciona e pontua as melhores oportunidades de educação superior do catálogo Nubo (148.424 oportunidades MEC ativas + parceiros) e persiste os resultados na tabela `user_opportunity_matches`.

O output é um conjunto de no máximo **104 linhas por usuário** (TOP 100 MEC + até 4 partners), que a função `get_opportunities_for_user` lê para montar o feed "Para Você".

---

## 2. Arquitetura de Acionamento

```
Usuário salva preferências / notas ENEM
         │
         ▼
  Trigger PostgreSQL
  (after INSERT OR UPDATE)
  on user_preferences / user_enem_scores
         │
         ▼
  trg_enqueue_calculate_match_v3()
  ├── SET match_status = 'processing'
  └── extensions.http_post() via pg_net
      (fire-and-forget — não bloqueia a transação)
         │
         ▼
  Edge Function: calculate-match-v3
  ├── Resolve profile_id (JWT ou body)
  ├── SET match_status = 'processing'
  ├── supabase.rpc('calculate_match', { p_profile_id })
  ├── SET match_status = 'ready'   ← sucesso
  └── SET match_status = 'error'   ← qualquer exceção
```

O design é **assíncrono** por necessidade: o scoring de 3.000 oportunidades leva vários segundos e não pode bloquear a transação do usuário. A UI lê `match_status` para exibir loading/ready/error.

---

## 3. Funil de Candidatos (Entrada do Motor)

O motor opera sobre um conjunto assimétrico de candidatos:

### 3.1 Partners — Sem Funil

```sql
SELECT * FROM partner_opportunities WHERE status = 'approved'
```

**Todos os parceiros aprovados entram sempre**, independente de qualquer preferência do usuário. Atualmente: 4 partners. Sem filtro, sem LIMIT.

**Racional:** parceiros são clientes Nubo com visibilidade garantida por contrato. O modelo de negócio exige que apareçam para todos os usuários.

### 3.2 MEC — Funil Assimétrico em 3 Caminhos

O catálogo MEC tem **93.380 ProUni (2025)** e **55.044 SISU (2026)** = 148.424 oportunidades. Rodar o scoring completo sobre todas seria inviável (~30s+ de query). O funil determina qual subconjunto entra:

#### Path A — Filtros Ativos (caso principal)

Ativado quando o usuário declarou ao menos uma preferência: `program_preference`, `course_interest`, `state_preference` ou `preferred_shifts`.

```
Filtro 1 — Programa:
  opportunity_type = v_program_preference   (ex: 'prouni')
  [ignorado se 'indiferente' ou NULL]

Filtro 2 — Curso de Interesse:
  course_name ILIKE '%Medicina%'            (cada item do array)
  [ignorado se array vazio ou NULL]

Filtro 3 — Estado:
  campus.state = v_state_preference         (ex: 'SP')
  [ignorado se NULL]

Filtro 4 — Turno:
  opportunity.shift = ANY(v_preferred_shifts)
  [ignorado se array vazio ou NULL]

Cap de segurança: ORDER BY cutoff_score DESC LIMIT 3000
  → prioriza as oportunidades mais competitivas antes do scoring
```

Exemplo do usuário real:
- `program_preference = 'prouni'` + `preferred_shifts = ['Matutino','Integral','Vespertino']`
- 148.424 → **12.274** após filtros → **3.000** após cap

#### Path B — Sem Filtros + Tem Localização

Ativado quando `v_has_funnel_filters = false` e `device_lat/lon` estão preenchidos.

```sql
WHERE haversine_km(v_lat, v_lon, campus_lat, campus_lon) <= 500
ORDER BY cutoff_score DESC LIMIT 3000
```

Semântica: "me mostra oportunidades num raio de 500 km de onde estou".

#### Path C — Sem Filtros + Sem Localização

Fallback total. Sample aleatório do catálogo para evitar timeout.

```sql
ORDER BY RANDOM() LIMIT 2000
```

---

## 4. O Pipeline de Scoring (6 CTEs)

Cada candidato (MEC ou partner) passa pelos seguintes estágios em sequência:

```
all_opportunities (3000 MEC + 4 partners)
        │
        ▼
scored_performance   → meets_income + weighted_enem_score
        │
        ▼
scored_academic      → academic_score (0–100)
        │
        ▼
scored_preferences   → shift_score, inst_program_score_raw, course_score
        │
        ▼
scored_location      → inst_program_score, distance_score, regional_bonus
        │
        ▼
composite            → base_score (fórmula dos 3 pilares)
        │
        ▼
boosted              → final_score (base + boosts) + details JSONB
        │
        ▼
course_best          → DISTINCT ON course_id → 1 linha por curso
```

### Estágio 1 — `scored_performance`: Elegibilidade de Renda

Antes de qualquer cálculo de score, o motor verifica se o usuário **pode** concorrer à vaga:

| Modalidade | Condição de exclusão (`meets_income = false`) |
|---|---|
| ProUni Integral | `family_income_per_capita > 1.5 × R$ 1.518 = R$ 2.277` |
| ProUni Parcial | `family_income_per_capita > 3.0 × R$ 1.518 = R$ 4.554` |
| SISU cotas de renda | `concurrency_type ILIKE '%renda%'` + renda > 1.5 SM |
| Partner com limite | `eligibility_criteria.per_capita_income_limit` |

Se `meets_income = false` → `final_score = 0.0`. A vaga ainda é persistida no `user_opportunity_matches` mas não aparece na UI (filtro `match_score > 0` no RPC de leitura).

O mesmo estágio calcula o **ENEM ponderado por área**:

```
weighted_enem = (
    nota_linguagens    × peso_linguagens    +
    nota_humanas       × peso_humanas       +
    nota_natureza      × peso_natureza      +
    nota_matematica    × peso_matematica    +
    nota_redacao       × peso_redacao
) / soma_dos_pesos
```

Os pesos (`peso_*`) vêm da tabela `opportunitiessisuvacancies` — são os pesos reais publicados pelo MEC por curso/vaga SISU. Para ProUni e partners sem pesos, usa-se a média simples das 5 áreas.

O motor escolhe automaticamente o **melhor ano de ENEM** dos últimos 3, selecionando aquele com maior soma bruta entre todos os anos disponíveis em `user_enem_scores`.

### Estágio 2 — `scored_academic`: Score Acadêmico (0–100)

Compara o ENEM ponderado do aluno com o `cutoff_score` da vaga:

```
Se nota >= corte:
    academic_score = 100.0   (aprovado com folga)

Se nota < corte:
    academic_score = max(0, 100 - (corte - nota) × 0.5)
    → cada ponto abaixo do corte reduz 0.5 pontos no score
    → deficit de 200 pontos = score zero

Se não há cutoff_score:
    academic_score = min(100, nota / 700 × 100)
    → referência: 700 pontos = 100%

Se não há ENEM:
    academic_score = 50.0    (neutro — não penaliza, não favorece)
```

### Estágio 3 — `scored_preferences`: Alinhamento de Preferências

Três sub-scores independentes, cada um de 0–100:

**Turno (shift_score)**
```
Sem preferência declarada → 50  (neutro)
Turno null na vaga        → 50
Turno bate               → 100
Turno não bate           → 0
```

**Instituição/Programa (inst_program_score_raw)**
Soma de dois sub-critérios (0–100 cada), depois normalizado para 0–100:
```
university_preference:
  'indiferente' ou NULL → 50
  'publica' + SISU      → 100
  'privada' + ProUni    → 100
  não bate              → 20

program_preference:
  'indiferente' ou NULL → 50
  'sisu' + SISU         → 100
  'prouni' + ProUni     → 100
  não bate              → 20
```

**Curso (course_score)**
```
Sem interesse declarado → 50  (neutro)
course_name ILIKE '%X%' → 100
não bate nenhum item    → 10
```

### Estágio 4 — `scored_location`: Localização

**Distância (distance_score)**
```
Sem lat/lon do usuário ou do campus → 40  (fallback neutro)

Com coordenadas:
    distance_score = max(0, 100 - haversine_km × 0.5)
    → 0 km   = 100 pontos
    → 200 km = 0 pontos (decresce linearmente)
```

A função `haversine_km` calcula a distância real em km usando a fórmula de Haversine (leva em conta a curvatura da Terra).

**Bônus Regional**
```
campus.state = state_preference  → +30 pontos
campus.city  ILIKE location_pref → +30 pontos
```

O bônus é somado ao `distance_score` antes de ser limitado a 100.

### Estágio 5 — `composite`: Fórmula dos 3 Pilares

```
base_score = (
    0.40 × academic_score
  + 0.30 × (shift_score × 0.333 + inst_program_score × 0.333 + course_score × 0.334)
  + 0.20 × min(100, distance_score + regional_bonus)
)
```

| Pilar | Peso | Componentes |
|---|---|---|
| Performance & Elegibilidade | 40% | academic_score |
| Alinhamento de Preferências | 30% | turno (33%) + instituição/programa (33%) + curso (34%) |
| Localização & Mobilidade | 20% | distância Haversine + bônus regional |

O peso restante (10%) não está implementado na fórmula atual mas aparece no `match_config` como `quota_weight` — reservado para scoring de cotas no roadmap.

Se `meets_income = false` → `base_score = 0.0` (independente dos pilares).

### Estágio 6 — `boosted`: Boosts e Score Final

**Partner Boost**
```
final_score = min(
    base_score × 1.15,
    base_score + 20
)
```
Partners elegíveis recebem multiplicador de 15%, limitado a +20 pontos absolutos. O cap evita que partners de baixo score saltem artificialmente para o topo.

**Idle Vacancy Boost**
Para vagas MEC com vagas ociosas em 2025 (`vagas_ociosas_2025 > 0`):
```
boost = min(5.0, vagas_ociosas_2025 × 0.5)
```
Incentiva o preenchimento de vagas com histórico de ociosidade.

**`match_details` JSONB**
Cada linha persistida carrega o breakdown completo do score:
```json
{
  "meets_income": true,
  "academic_score": 100.0,
  "weighted_enem_score": 728.0,
  "cutoff_score": 610.54,
  "shift_score": 100.0,
  "inst_program_score": 50.0,
  "course_score": 100.0,
  "distance_score": 40.0,
  "regional_bonus": 0.0,
  "base_score": 73.01,
  "is_partner": false,
  "boost_applied": false,
  "idle_vacancy_boost_applied": false,
  "opportunity_type": "prouni"
}
```

---

## 5. Agregação por Curso

O catálogo MEC tem múltiplas oportunidades para o mesmo curso (SISU ampla concorrência, SISU cotas L1, L2, L5, ProUni Integral, Parcial, etc.). Para não mostrar o mesmo curso várias vezes:

```sql
SELECT DISTINCT ON (COALESCE(course_id::text, unified_id))
    unified_id,
    LEAST(100, round(final_score, 2)) AS final_score,
    details
FROM boosted
ORDER BY COALESCE(course_id::text, unified_id), final_score DESC
```

**Semântica:** para cada `course_id`, mantém apenas a oportunidade com maior `final_score`. Partners não têm `course_id`, então cada um é tratado como entidade única (`unified_id` como chave).

Isso colapsa, por exemplo, 6 vagas de "Medicina UFSP" em 1 card com o melhor score disponível.

---

## 6. Persistência

Após a agregação, dois blocos de INSERT no mesmo statement:

```sql
-- TOP 100 MEC por final_score DESC
INSERT INTO user_opportunity_matches (...)
SELECT p_profile_id, unified_id, final_score, details
FROM course_best WHERE NOT is_partner ORDER BY final_score DESC LIMIT 100

UNION ALL

-- TODOS os partners aprovados (sem LIMIT)
SELECT p_profile_id, unified_id, final_score, details
FROM course_best WHERE is_partner;
```

**Por que TOP 100?** O scoring por curso já elimina duplicatas. 100 cursos únicos com score personalizado são suficientes para o feed sem sobrecarregar a leitura.

**Por que partners sem LIMIT?** Decisão de produto: parceiros pagam por visibilidade garantida. Com 4 parceiros hoje, o custo é zero.

O `DELETE FROM user_opportunity_matches WHERE profile_id = p_profile_id` antes do INSERT garante que re-execuções sejam idempotentes.

---

## 7. Leitura — `get_opportunities_for_user`

```sql
SELECT vo.*, uom.match_score, uom.match_details
FROM v_unified_opportunities vo
JOIN user_opportunity_matches uom ON uom.unified_opportunity_id = vo.unified_id
WHERE uom.profile_id = p_profile_id
  AND uom.match_score > 0
ORDER BY vo.is_partner DESC, uom.match_score DESC NULLS LAST
LIMIT p_limit OFFSET (p_page * p_limit);
```

Ordem de exibição:
1. Partners sempre primeiro (`is_partner DESC`)
2. MEC por `match_score DESC` dentro da mesma página

O filtro `match_score > 0` exclui vagas onde `meets_income = false` — o usuário não vê vagas para as quais é inelegível por renda.

---

## 8. Limitações Conhecidas e Roadmap

| Limitação | Impacto | Solução Planejada |
|---|---|---|
| `distance_score` fallback = 40 quando sem localização | Todos os resultados empatam no pilar de localização | Solicitar localização no onboarding ou usar UF como proxy |
| `inst_program_score = 50` com `university_preference = 'indiferente'` | Pilar de preferência saturado → scores idênticos para usuários sem preferência de universidade | Normalizar para refletir melhor a ausência de preferência (ex: 100 neutro, não 50) |
| Funil cap de 3.000 por path | Usuários sem curso declarado recebem amostra, não ranking exaustivo | Índice composto + amostragem estratificada por área |
| `quota_weight` (10%) sem implementação | Score não considera elegibilidade a cotas raciais/sociais | Cruzar `concurrency_type` com perfil autodeclarado do usuário |
| Score igual para todos os matches de um usuário sem localização | UI não diferencia oportunidades | Tiebreaker por proximidade ao corte (`cutoff_score` vs `weighted_enem`) |
