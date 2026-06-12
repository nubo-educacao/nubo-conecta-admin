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
    const { markdownContent, question } = await req.json();

    if (!markdownContent || !question) {
      throw new Error("Os campos 'markdownContent' e 'question' são obrigatórios.");
    }

    const API_KEY = Deno.env.get("GOOGLE_API_KEY") || Deno.env.get("GEMINI_API_KEY");
    if (!API_KEY) {
      throw new Error("GOOGLE_API_KEY não configurada.");
    }

    const geminiUrl = `https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=${API_KEY}`;
    
    const prompt = `Você é a Cloudinha, uma assistente virtual especializada em ajudar usuários a entenderem documentos.
Responda a pergunta do usuário com base ESTRITAMENTE no documento fornecido abaixo.
Se a resposta não puder ser inferida pelo documento, informe educadamente que não encontrou a informação no texto.

--- DOCUMENTO INÍCIO ---
${markdownContent}
--- DOCUMENTO FIM ---

Pergunta do Usuário:
${question}
`;

    const body = {
      contents: [{
        parts: [
          { text: prompt }
        ]
      }],
      generationConfig: {
        temperature: 0.3,
        maxOutputTokens: 2048
      }
    };

    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), 25000);

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

    if (!text && candidate?.finishReason !== "STOP" && candidate?.finishReason !== "MAX_TOKENS") {
      throw new Error(`Resposta do Gemini veio vazia. Motivo: ${candidate?.finishReason}`);
    }

    return new Response(JSON.stringify({ answer: text.trim() }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });

  } catch (error) {
    console.error("Error in test-knowledge:", error);
    const status = error.name === 'AbortError' ? 504 : 500;
    const message = error.name === 'AbortError' ? "Timeout no processamento da IA" : error.message;
    
    return new Response(JSON.stringify({ error: message }), {
      status,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
