import "jsr:@supabase/functions-js/edge-runtime.d.ts"
import { serve } from "https://deno.land/std@0.168.0/http/server.ts"

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, GET, OPTIONS, PUT, DELETE, PATCH',
}

const GITHUB_OWNER = Deno.env.get("GITHUB_OWNER") || "nubo-educacao"; 

// A variável de forms 'application' já é o nome exato do repo na organização!
function mapApplicationToRepo(application: string): string {
  return application || "nubo-conecta-admin";
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    const GITHUB_PAT = Deno.env.get("GITHUB_PAT");
    if (!GITHUB_PAT) throw new Error("GITHUB_PAT não configurado no Vault.");

    const url = new URL(req.url);

    if (req.method === 'GET') {
      // Buscar todas as issues dos repositórios sem depender do GitHub Projects (já que o plano Free limita os workflows)
      const searchQuery = `is:issue is:open repo:${GITHUB_OWNER}/nubo-hub-admin repo:${GITHUB_OWNER}/nubo-conecta-admin repo:${GITHUB_OWNER}/nubo-conecta-app repo:${GITHUB_OWNER}/cloudinha-conecta-agent`;
      const encodedQuery = encodeURIComponent(searchQuery);

      const githubRes = await fetch(`https://api.github.com/search/issues?q=${encodedQuery}`, {
        headers: {
          'Authorization': `Bearer ${GITHUB_PAT}`,
          'Accept': 'application/vnd.github.v3+json',
        }
      });
      const data = await githubRes.json();
      // O Search API devolve "{ items: [...] }", precisamos retornar só a array pra manter a compatibilidade
      return new Response(JSON.stringify(data.items || []), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    if (req.method === 'PATCH') {
      const body = await req.json();
      const { issueNumber, repo, action } = body;

      if (!issueNumber || !repo || !action) {
        throw new Error("Parâmetros incompletos para PATCH");
      }

      if (action === 'aprovar') {
        // Remover status:concluido se houver
        await fetch(`https://api.github.com/repos/${GITHUB_OWNER}/${repo}/issues/${issueNumber}/labels/status:concluido`, {
          method: 'DELETE', headers: { 'Authorization': `Bearer ${GITHUB_PAT}`, 'Accept': 'application/vnd.github.v3+json' }
        }).catch(()=>null);

        // Garantir que a issue tá aberta
        await fetch(`https://api.github.com/repos/${GITHUB_OWNER}/${repo}/issues/${issueNumber}`, {
          method: 'PATCH',
          headers: { 'Authorization': `Bearer ${GITHUB_PAT}`, 'Accept': 'application/vnd.github.v3+json', 'Content-Type': 'application/json' },
          body: JSON.stringify({ state: 'open' })
        });
        // Injetar Label status:aprovar
        const labelRes = await fetch(`https://api.github.com/repos/${GITHUB_OWNER}/${repo}/issues/${issueNumber}/labels`, {
          method: 'POST',
          headers: { 'Authorization': `Bearer ${GITHUB_PAT}`, 'Accept': 'application/vnd.github.v3+json', 'Content-Type': 'application/json' },
          body: JSON.stringify({ labels: ['status:aprovar'] })
        });
        const data = await labelRes.json();
        return new Response(JSON.stringify(data), { headers: { ...corsHeaders, 'Content-Type': 'application/json' }});
      }

      if (action === 'abrir') {
        // Remover a label status:aprovar se existir
        await fetch(`https://api.github.com/repos/${GITHUB_OWNER}/${repo}/issues/${issueNumber}/labels/status:aprovar`, {
          method: 'DELETE', headers: { 'Authorization': `Bearer ${GITHUB_PAT}`, 'Accept': 'application/vnd.github.v3+json' }
        }).catch(()=>null);
        
        // Remover a label status:concluido se existir
        await fetch(`https://api.github.com/repos/${GITHUB_OWNER}/${repo}/issues/${issueNumber}/labels/status:concluido`, {
          method: 'DELETE', headers: { 'Authorization': `Bearer ${GITHUB_PAT}`, 'Accept': 'application/vnd.github.v3+json' }
        }).catch(()=>null);

        // Garantir que está aberta
        const patchRes = await fetch(`https://api.github.com/repos/${GITHUB_OWNER}/${repo}/issues/${issueNumber}`, {
          method: 'PATCH',
          headers: { 'Authorization': `Bearer ${GITHUB_PAT}`, 'Accept': 'application/vnd.github.v3+json', 'Content-Type': 'application/json' },
          body: JSON.stringify({ state: 'open' })
        });
        const data = await patchRes.json();
        return new Response(JSON.stringify(data), { headers: { ...corsHeaders, 'Content-Type': 'application/json' }});
      }

      if (action === 'concluir') {
        // Remover status:aprovar se existir
        await fetch(`https://api.github.com/repos/${GITHUB_OWNER}/${repo}/issues/${issueNumber}/labels/status:aprovar`, {
          method: 'DELETE', headers: { 'Authorization': `Bearer ${GITHUB_PAT}`, 'Accept': 'application/vnd.github.v3+json' }
        }).catch(()=>null);

        // Garantir estado aberto ainda (cron fecha depois)
        await fetch(`https://api.github.com/repos/${GITHUB_OWNER}/${repo}/issues/${issueNumber}`, {
          method: 'PATCH',
          headers: { 'Authorization': `Bearer ${GITHUB_PAT}`, 'Accept': 'application/vnd.github.v3+json', 'Content-Type': 'application/json' },
          body: JSON.stringify({ state: 'open' })
        });
        
        // Adicionar label de concluido
        const patchRes = await fetch(`https://api.github.com/repos/${GITHUB_OWNER}/${repo}/issues/${issueNumber}/labels`, {
          method: 'POST',
          headers: { 'Authorization': `Bearer ${GITHUB_PAT}`, 'Accept': 'application/vnd.github.v3+json', 'Content-Type': 'application/json' },
          body: JSON.stringify({ labels: ['status:concluido'] })
        });
        const data = await patchRes.json();
        return new Response(JSON.stringify(data), { headers: { ...corsHeaders, 'Content-Type': 'application/json' }});
      }

      throw new Error("Ação PATCH desconhecida");
    }

    if (req.method === 'POST') {
      const body = await req.json();
      const { title, body: issueBody, application, type, version } = body;
      
      const repo = mapApplicationToRepo(application);

      // Formatar o body com markdown listando specs extra
      const formattedBody = `
**Versão:** ${version}
**Aplicação:** ${application}
**Tipo:** ${type}

${issueBody}
      `.trim();

      const githubRes = await fetch(`https://api.github.com/repos/${GITHUB_OWNER}/${repo}/issues`, {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${GITHUB_PAT}`,
          'Accept': 'application/vnd.github.v3+json',
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({
          title,
          body: formattedBody,
          labels: [type]
        })
      });

      const data = await githubRes.json();
      return new Response(JSON.stringify(data), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    return new Response(JSON.stringify({ error: 'Method Not Allowed' }), {
      status: 405,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });

  } catch (error) {
    return new Response(JSON.stringify({ error: (error as Error).message }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 400,
    })
  }
})
