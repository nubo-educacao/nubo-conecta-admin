import React from "react";

const SNAPS_PROJECT_ID = import.meta.env.VITE_SNAPS_PROJECT_ID as string;
const SNAPS_API_KEY = import.meta.env.VITE_SNAPS_API_KEY as string;
const SNAPS_API_URL = import.meta.env.VITE_SNAPS_API_URL as string;

export default function Docs() {
  return (
    <div className="flex-1 space-y-4 p-8 pt-6 animate-in fade-in slide-in-from-bottom-2">
      <div className="flex items-center justify-between">
        <h2 className="text-3xl font-bold tracking-tight">
          Documentos de Governança
        </h2>
        <span className="text-sm text-muted-foreground">
          Powered by Snaps
        </span>
      </div>

      <snaps-governance-docs
        project-id={SNAPS_PROJECT_ID}
        api-key={SNAPS_API_KEY}
        api-url={SNAPS_API_URL}
      />
    </div>
  );
}
