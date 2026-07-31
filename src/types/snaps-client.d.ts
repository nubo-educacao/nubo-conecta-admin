/// <reference types="vite/client" />

/**
 * Type declarations for @snaps/client Web Components.
 * These are framework-agnostic custom elements loaded via the UMD bundle
 * at public/snaps/snaps-client.umd.js
 */
declare namespace JSX {
  interface IntrinsicElements {
    "snaps-support-board": React.DetailedHTMLProps<
      React.HTMLAttributes<HTMLElement> & {
        "project-id"?: string;
        "api-key"?: string;
        "api-url"?: string;
      },
      HTMLElement
    >;
    "snaps-roadmap-board": React.DetailedHTMLProps<
      React.HTMLAttributes<HTMLElement> & {
        "project-id"?: string;
        "api-key"?: string;
        "api-url"?: string;
      },
      HTMLElement
    >;
    "snaps-governance-docs": React.DetailedHTMLProps<
      React.HTMLAttributes<HTMLElement> & {
        "project-id"?: string;
        "api-key"?: string;
        "api-url"?: string;
      },
      HTMLElement
    >;
  }
}
