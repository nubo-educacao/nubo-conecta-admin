import { serve } from "https://deno.land/std@0.168.0/http/server.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const { pdfBase64, chunkIndex = 0, totalChunks = 1 } = await req.json();

    if (!pdfBase64) {
      throw new Error("O campo 'pdfBase64' é obrigatório.");
    }

    const API_KEY = Deno.env.get("GOOGLE_API_KEY") || Deno.env.get("GEMINI_API_KEY");
    if (!API_KEY) {
      throw new Error("GOOGLE_API_KEY não configurada.");
    }

    console.log(`Recebido PDF Base64 (Tamanho: ${Math.round(pdfBase64.length / 1024)} KB)`);

    // Estratégia: Enviar diretamente para a API de conteúdo. 
    // Para evitar TLS Handshake EOF em Edge Functions com corpos gigantes, 
    // garantimos que o prompt seja enxuto e usamos Gemini 2.0 Flash.

    const geminiUrl = `https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=${API_KEY}`;
    
    let prompt = "";
    if (chunkIndex === 0) {
        prompt = `Analise o PDF e extraia os metadados. Você DEVE sempre retornar a resposta neste exato formato (Frontmatter + Markdown bruto), sem blocos de código em volta:

---
title: Título curto
description: Resumo (1-2 frases)
category_name: uma destas: partner, prouni, sisu, cloudinha, passport, general
partner_name: Nome do parceiro ou vazio
keywords: tag1, tag2, tag3
---
[INICIO DO MARKDOWN]
Conteúdo MD completo e detalhado (tabelas e listas inclusas, não resuma o texto)
[FIM DO MARKDOWN]`;
    } else {
        prompt = `Você está recebendo a PARTE ${chunkIndex + 1} de ${totalChunks} de um documento longo. Transcreva esta parte para Markdown. Retorne APENAS o texto Markdown bruto, sem formatação JSON, sem blocos de código em volta:
[INICIO DO MARKDOWN]
Conteúdo MD completo e detalhado desta parte (tabelas e listas inclusas, não resuma o texto)
[FIM DO MARKDOWN]`;
    }

    const body = {
      contents: [{
        parts: [
          { text: prompt },
          {
            inlineData: {
              mimeType: "application/pdf",
              data: pdfBase64
            }
          }
        ]
      }],
      generationConfig: {
        temperature: 0,
        maxOutputTokens: 8192
      },
      safetySettings: [
        { category: "HARM_CATEGORY_HARASSMENT", threshold: "BLOCK_NONE" },
        { category: "HARM_CATEGORY_HATE_SPEECH", threshold: "BLOCK_NONE" },
        { category: "HARM_CATEGORY_SEXUALLY_EXPLICIT", threshold: "BLOCK_NONE" },
        { category: "HARM_CATEGORY_DANGEROUS_CONTENT", threshold: "BLOCK_NONE" }
      ]
    };

    console.log("Chamando Gemini 2.0 Flash...");
    
    // Timeout de segurança
    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), 55000);

    const response = await fetch(geminiUrl, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
      signal: controller.signal
    });
    
    clearTimeout(timeoutId);

    if (!response.ok) {
      const errorText = await response.text();
      console.error("Erro Gemini:", response.status, errorText);
      throw new Error(`Erro na API Gemini (${response.status}) - ${errorText}`);
    }

    const data = await response.json();
    const candidate = data.candidates?.[0];
    const text = candidate?.content?.parts?.[0]?.text || "";

    console.log("Finish Reason:", candidate?.finishReason);
    console.log("Token Count Usage:", JSON.stringify(data.usageMetadata));

    if (!text && candidate?.finishReason !== "STOP" && candidate?.finishReason !== "MAX_TOKENS") {
      throw new Error(`Resposta do Gemini veio vazia. Payload completo: ${JSON.stringify(data)}`);
    }

    let parsedText = text;
    // Limpeza genérica de blocos de código se houver
    if (parsedText.startsWith("\`\`\`markdown")) {
      parsedText = parsedText.replace(/^\`\`\`markdown\n/, "").replace(/\n\`\`\`$/, "");
    } else if (parsedText.startsWith("\`\`\`")) {
      parsedText = parsedText.replace(/^\`\`\`\n?/, "").replace(/\n?\`\`\`$/, "");
    }

    const result: any = { markdown: "" };

    if (chunkIndex === 0) {
        // Extrair frontmatter
        const frontmatterMatch = parsedText.match(/^---\n([\s\S]*?)\n---/);
        if (frontmatterMatch) {
            const lines = frontmatterMatch[1].split("\n");
            lines.forEach(line => {
                const colonIndex = line.indexOf(":");
                if (colonIndex > -1) {
                    const key = line.substring(0, colonIndex).trim();
                    const val = line.substring(colonIndex + 1).trim();
                    if (key === "keywords") {
                        result[key] = val.split(",").map(k => k.trim()).filter(k => k);
                    } else {
                        result[key] = val;
                    }
                }
            });
            parsedText = parsedText.replace(/^---\n[\s\S]*?\n---\n*/, "");
        }
    }

    // Limpar marcadores de inicio/fim
    parsedText = parsedText.replace(/\[INICIO DO MARKDOWN\]\n?/gi, "");
    parsedText = parsedText.replace(/\n?\[FIM DO MARKDOWN\]/gi, "");

    result.markdown = parsedText.trim();

    if (candidate?.finishReason === "MAX_TOKENS") {
      console.warn("Aviso: Trecho truncado por MAX_TOKENS mesmo após divisão. Markdown foi recuperado até onde deu.");
    }
    
    return new Response(JSON.stringify(result), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });

  } catch (error) {
    console.error("Error in pdf-to-markdown:", error);
    const status = error.name === 'AbortError' ? 504 : 500;
    const message = error.name === 'AbortError' ? "Timeout no processamento da IA" : error.message;
    
    return new Response(JSON.stringify({ error: message }), {
      status,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
