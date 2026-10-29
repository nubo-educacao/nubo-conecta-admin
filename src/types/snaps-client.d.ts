/// <reference types="vite/client" />

/**
 * Type declarations for @snaps/client Web Components.
 * These are framework-agnostic custom elements loaded via the UMD bundle
 * at public/snaps/snaps-client.umd.js (snaps-client 0.2.0).
 *
 * Os atributos espelham as `props` de cada elemento no bundle (camelCase →
 * kebab-case). No admin, `api-url` é sempre o proxy `/api/snaps` e `api-key`
 * leva o token da sessão Supabase, nunca a chave do Snaps.
 */
type SnapsBaseAttributes = React.HTMLAttributes<HTMLElement> & {
  "project-id"?: string;
  "api-key"?: string;
  "api-url"?: string;
};

declare namespace JSX {
  interface IntrinsicElements {
    "snaps-support-board": React.DetailedHTMLProps<
      SnapsBaseAttributes & {
        "default-tab"?: "active" | "history";
        "page-size"?: number | string;
        "app-name"?: string;
        /** 0.2.0 — referência do usuário enviada ao abrir uma sessão do chat de suporte. */
        "session-user-ref"?: string;
        /** 0.2.0 — trocar o valor reinicia a sessão do chat. */
        "session-key"?: string;
      },
      HTMLElement
    >;
    "snaps-roadmap-board": React.DetailedHTMLProps<
      SnapsBaseAttributes & {
        "show-backlog"?: boolean | string;
      },
      HTMLElement
    >;
    "snaps-governance-docs": React.DetailedHTMLProps<SnapsBaseAttributes, HTMLElement>;
    /** 0.2.0 — horas por pessoa, custo de IA do suporte (USD) e relatório PDF. */
    "snaps-costs-board": React.DetailedHTMLProps<SnapsBaseAttributes, HTMLElement>;
  }
}
