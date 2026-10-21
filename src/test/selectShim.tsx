import React from "react";

/**
 * Test-only stand-in for "@/components/ui/select": Radix Select does not open in jsdom
 * without pointer-capture polyfills, so each Select renders as one native <select>
 * labelled by its SelectTrigger's aria-label, with its SelectItems as options.
 */
type AnyProps = { children?: React.ReactNode; [key: string]: unknown };

function walk(node: React.ReactNode, visit: (el: React.ReactElement<AnyProps>) => void) {
  React.Children.forEach(node, (child) => {
    if (!React.isValidElement<AnyProps>(child)) return;
    visit(child);
    walk(child.props.children, visit);
  });
}

export function Select({ value, onValueChange, children }: { value?: string; onValueChange?: (v: string) => void; children?: React.ReactNode }) {
  let label: string | undefined;
  const options: { value: string; text: React.ReactNode }[] = [];
  walk(children, (el) => {
    if (el.type === SelectTrigger) label = el.props["aria-label"] as string | undefined;
    if (el.type === SelectItem) options.push({ value: el.props.value as string, text: el.props.children });
  });
  return (
    <select aria-label={label} value={value} onChange={(e) => onValueChange?.(e.target.value)}>
      {options.map((o) => <option key={o.value} value={o.value}>{o.text}</option>)}
    </select>
  );
}
export function SelectTrigger(_: AnyProps) { return null; }
export function SelectValue(_: AnyProps) { return null; }
export function SelectContent(_: AnyProps) { return null; }
export function SelectItem(_: AnyProps) { return null; }
