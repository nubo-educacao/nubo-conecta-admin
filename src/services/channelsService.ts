import { supabase } from "@/integrations/supabase/client";

// Produtização de Canal — camada de dados (TP-7 7D).
// Governance doc f74d1cd9 §3.1 e §3.2.
//
// A regra que organiza este arquivo: o construtor NÃO aceita digitação livre
// nos campos que viram UTM. Campanha, divulgador e plataforma são seleções;
// os cinco utm_* são DERIVADOS delas. Foi a digitação livre que produziu
// `dudinhanubo`, `ailanubo` e `felipebritonubo` como strings soltas, e um
// "Canal: Não definido" na maioria dos registros.

export interface Campaign {
    id: string;
    slug: string;
    name: string;
    objective: string | null;
    starts_at: string | null;
    ends_at: string | null;
    owner: string | null;
    active: boolean;
    created_at: string;
}

export interface Channel {
    id: string;
    slug: string;
    name: string;
    type: string;
    owner_name: string | null;
    active: boolean;
    archived_at: string | null;
}

export interface Platform {
    slug: string;
    name: string;
    category: string;
}

export interface ChannelMedium {
    slug: string;
    name: string;
    description: string | null;
}

export interface ChannelLink {
    id: string;
    code: string;
    nickname: string | null;
    destination_path: string;
    campaign_id: string | null;
    channel_id: string;
    platform_id: string | null;
    utm_source: string | null;
    utm_medium: string | null;
    utm_campaign: string | null;
    utm_content: string | null;
    utm_term: string | null;
    created_at: string;
    archived_at: string | null;
    campaign_name?: string | null;
    channel_name?: string | null;
    channel_type?: string | null;
    platform_name?: string | null;
    platform_category?: string | null;
}

export const APP_BASE_URL = "https://conecta.nuboeducacao.org.br";

/** Marcas de acentuação que o NFD separa da letra base (U+0300–U+036F). */
function isCombiningMark(ch: string): boolean {
    const code = ch.charCodeAt(0);
    return code >= 0x0300 && code <= 0x036f;
}

/**
 * Slugificação automática e invisível — §3.2.2.
 * "Disparo Ponte e Sol 09/03" vira `disparo-ponte-sol-09-03`. A data continua
 * existindo em `created_at`; o slug não precisa carregá-la.
 */
export function slugify(input: string): string {
    return Array.from(input.normalize("NFD"))
        // Comparacao por codepoint em vez de regex com range literal: os
        // combining marks sao invisiveis no editor, entao a versao em regex
        // e impossivel de revisar e facil de corromper num copy-paste.
        .filter((ch) => !isCombiningMark(ch))
        .join("")
        .toLowerCase()
        .replace(/[^a-z0-9]+/g, "-")
        .replace(/(^-+|-+$)/g, "")
        .slice(0, 60);
}

/**
 * Monta o código do link a partir das três seleções.
 * Legível de propósito: quem vê `insper-2026-dudinha-instagram` numa planilha
 * entende sem consultar o banco.
 */
export function buildLinkCode(
    campaignSlug: string | null,
    channelSlug: string,
    platformSlug: string | null,
): string {
    return [campaignSlug, channelSlug, platformSlug].filter(Boolean).join("-");
}

/**
 * Deriva os cinco UTM a partir das seleções, seguindo a convenção validada com
 * o marketing:
 *
 *   Canal (categoria) = derivado da plataforma   → nunca digitado
 *   Campanha          = utm_campaign
 *   Source            = a plataforma  (Instagram)
 *   Medium            = o tipo do canal (influencer)
 *   Identifier        = o divulgador (dudinha)  → utm_content
 */
export function deriveUtms(opts: {
    campaignSlug: string | null;
    channelSlug: string;
    channelType: string;
    platformSlug: string | null;
    term?: string | null;
}) {
    return {
        utm_source: opts.platformSlug ?? "direct",
        utm_medium: opts.channelType,
        utm_campaign: opts.campaignSlug,
        utm_content: opts.channelSlug,
        utm_term: opts.term?.trim() || null,
    };
}

export function buildShareUrl(code: string): string {
    return `${APP_BASE_URL}/r/${code}`;
}

// ─── Leitura ─────────────────────────────────────────────────────────────────

export async function getCampaigns(): Promise<Campaign[]> {
    const { data, error } = await supabase
        .from("campaigns")
        .select("*")
        .order("created_at", { ascending: false });
    if (error) throw error;
    return (data ?? []) as Campaign[];
}

export async function getChannels(includeArchived = false): Promise<Channel[]> {
    let query = supabase.from("channels").select("*").order("name");
    if (!includeArchived) query = query.is("archived_at", null);
    const { data, error } = await query;
    if (error) throw error;
    return (data ?? []) as Channel[];
}

export async function getPlatforms(): Promise<Platform[]> {
    const { data, error } = await supabase
        .from("platforms")
        .select("*")
        .order("category")
        .order("name");
    if (error) throw error;
    return (data ?? []) as Platform[];
}

export async function getMediums(): Promise<ChannelMedium[]> {
    const { data, error } = await supabase.from("channel_mediums").select("*").order("name");
    if (error) throw error;
    return (data ?? []) as ChannelMedium[];
}

export async function getChannelLinks(includeArchived = false): Promise<ChannelLink[]> {
    // Embeds nomeados explicitamente: `channel_links` tem DUAS FKs que poderiam
    // ser confundidas na inferência do PostgREST se deixadas implícitas.
    let query = supabase
        .from("channel_links")
        .select(`
            *,
            campaigns ( name ),
            channels ( name, type ),
            platforms ( name, category )
        `)
        .order("created_at", { ascending: false });

    if (!includeArchived) query = query.is("archived_at", null);

    const { data, error } = await query;
    if (error) throw error;

    return ((data ?? []) as any[]).map((row) => ({
        ...row,
        campaign_name: row.campaigns?.name ?? null,
        channel_name: row.channels?.name ?? null,
        channel_type: row.channels?.type ?? null,
        platform_name: row.platforms?.name ?? null,
        platform_category: row.platforms?.category ?? null,
    })) as ChannelLink[];
}

// ─── Escrita ─────────────────────────────────────────────────────────────────

export async function createCampaign(input: {
    name: string;
    objective?: string | null;
    starts_at?: string | null;
    ends_at?: string | null;
    owner?: string | null;
}): Promise<Campaign> {
    const { data, error } = await supabase
        .from("campaigns")
        .insert({
            slug: slugify(input.name),
            name: input.name.trim(),
            objective: input.objective?.trim() || null,
            starts_at: input.starts_at || null,
            ends_at: input.ends_at || null,
            owner: input.owner?.trim() || null,
        })
        .select()
        .single();
    if (error) throw error;
    return data as Campaign;
}

export async function createChannel(input: {
    name: string;
    type: string;
    owner_name?: string | null;
}): Promise<Channel> {
    const { data, error } = await supabase
        .from("channels")
        .insert({
            slug: slugify(input.name),
            name: input.name.trim(),
            type: input.type,
            owner_name: input.owner_name?.trim() || null,
        })
        .select()
        .single();
    if (error) throw error;
    return data as Channel;
}

export async function createChannelLink(input: {
    campaign: Campaign | null;
    channel: Channel;
    platform: Platform | null;
    nickname?: string | null;
    destinationPath?: string;
    term?: string | null;
}): Promise<ChannelLink> {
    const code = buildLinkCode(
        input.campaign?.slug ?? null,
        input.channel.slug,
        input.platform?.slug ?? null,
    );

    const utms = deriveUtms({
        campaignSlug: input.campaign?.slug ?? null,
        channelSlug: input.channel.slug,
        channelType: input.channel.type,
        platformSlug: input.platform?.slug ?? null,
        term: input.term,
    });

    const { data, error } = await supabase
        .from("channel_links")
        .insert({
            code,
            campaign_id: input.campaign?.id ?? null,
            channel_id: input.channel.id,
            platform_id: input.platform?.slug ?? null,
            nickname: input.nickname?.trim() || null,
            destination_path: input.destinationPath?.trim() || "/",
            ...utms,
        })
        .select()
        .single();

    if (error) throw error;
    return data as ChannelLink;
}

/**
 * Arquiva, nunca deleta. Link arquivado continua resolvendo em /r/<code> — a
 * peça já foi distribuída e quebrá-la perde a atribuição de quem clicar depois.
 */
export async function archiveChannelLink(id: string): Promise<void> {
    const { error } = await supabase
        .from("channel_links")
        .update({ archived_at: new Date().toISOString() })
        .eq("id", id);
    if (error) throw error;
}
