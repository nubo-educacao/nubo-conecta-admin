import type { ReactNode } from 'react';
import { UserRound } from 'lucide-react';
import { DialogDescription, DialogHeader, DialogTitle } from '@/components/ui/dialog';

export const studentModalClassName = 'flex h-[88vh] max-h-[900px] w-[calc(100%-2rem)] max-w-4xl flex-col gap-0 overflow-hidden rounded-2xl p-0';
export const studentTabsClassName = 'grid h-11 w-full rounded-xl bg-muted/60 p-1';

export function StudentModalHeader({ title, studentName, description, action }: {
  title: string; studentName?: string | null; description: string; action?: ReactNode;
}) {
  return <DialogHeader className="shrink-0 border-b px-6 py-5 text-left sm:px-8">
    <div className="flex items-center gap-3 pr-7">
      <span className="flex h-11 w-11 shrink-0 items-center justify-center rounded-full bg-primary/10 text-primary">
        <UserRound aria-hidden="true" className="h-5 w-5" />
      </span>
      <div className="min-w-0 flex-1">
        <DialogTitle className="text-lg font-semibold tracking-tight">{title}</DialogTitle>
        <DialogDescription className="mt-1 truncate text-sm">{studentName || description}</DialogDescription>
      </div>
      {action}
    </div>
  </DialogHeader>;
}
