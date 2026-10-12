export interface MessageDateRange {
  from: string;
  to: string;
}

// chat_messages stores the role as sender (not role) in staging and production.
// Only sender=user represents user volume; system/cloudinha/null never do.
// deno-lint-ignore no-explicit-any
export async function fetchUserMessageStats(supabase: any, range?: MessageDateRange, now = new Date()) {
  const to = range ? new Date(range.to) : now;
  const from = range ? new Date(range.from) : new Date(to.getTime() - 7 * 86400000);
  if (!Number.isFinite(from.getTime()) || !Number.isFinite(to.getTime()) || to <= from) {
    throw new Error('Período inválido');
  }
  const previousFrom = new Date(from.getTime() - (to.getTime() - from.getTime()));
  const count = (start?: Date, end?: Date) => {
    let query = supabase.from('chat_messages').select('*', { count: 'exact', head: true }).eq('sender', 'user');
    if (start) query = query.gte('created_at', start.toISOString());
    if (end) query = query.lt('created_at', end.toISOString());
    return query;
  };
  const [current, previous, total] = await Promise.all([
    count(from, to), count(previousFrom, from), range ? Promise.resolve(null) : count(),
  ]);
  for (const result of [current, previous, total]) {
    if (result && (result.error || typeof result.count !== 'number')) {
      throw new Error(result.error?.message ?? 'Contagem de mensagens indisponível');
    }
  }
  return {
    totalMessages: range ? current.count : total.count,
    messagesChange: previous.count === 0 ? (current.count > 0 ? 100 : 0)
      : Math.round(((current.count - previous.count) / previous.count) * 100),
  };
}
