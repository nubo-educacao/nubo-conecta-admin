// Mensagens de erro do login em PT-BR, mapeadas por code/status do Supabase Auth.
// Nunca exibimos error.message cru: ele vem em inglês e pode vazar detalhe interno.

type AuthErrorLike = { code?: string; status?: number; name?: string; message?: string };

const GENERIC = "Não foi possível entrar. Tente novamente em instantes.";
const NETWORK = "Falha de conexão. Verifique sua internet e tente novamente.";
const RATE_LIMIT = "Muitas tentativas seguidas. Aguarde alguns instantes e tente novamente.";

export function loginErrorMessage(error: unknown): string {
  if (!error || typeof error !== "object") return GENERIC;
  const { code, status, name, message } = error as AuthErrorLike;

  if (code === "invalid_credentials") return "E-mail ou senha incorretos. Confira os dados e tente novamente.";
  if (code === "email_not_confirmed") return "Seu e-mail ainda não foi confirmado. Confirme o e-mail para entrar.";
  if (code === "user_banned") return "Esta conta está suspensa. Fale com a equipe Nubo.";
  if (status === 429 || code === "over_request_rate_limit" || code === "over_email_send_rate_limit") return RATE_LIMIT;

  if (
    status === 0 ||
    name === "AuthRetryableFetchError" ||
    error instanceof TypeError ||
    /failed to fetch|network/i.test(message ?? "")
  ) {
    return NETWORK;
  }

  return GENERIC;
}
