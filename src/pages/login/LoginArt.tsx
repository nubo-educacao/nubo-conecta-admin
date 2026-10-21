import { useId } from "react";
import { cn } from "@/lib/utils";

// Position each cloud outside the animated group: CSS transforms must never
// replace the composition's placement. All artwork stays inline and decorative.
const LOGIN_ART_CSS = `
@keyframes login-cloud-drift {
  from { transform: translate3d(-12px, 0, 0); }
  to   { transform: translate3d(12px, 4px, 0); }
}
.login-cloud {
  animation: login-cloud-drift 28s ease-in-out infinite alternate;
  will-change: transform;
}
.login-cloud-b { animation-duration: 36s; animation-delay: -12s; animation-direction: alternate-reverse; }
.login-cloud-c { animation-duration: 44s; animation-delay: -24s; }
.login-cloud-shape { position: absolute; overflow: visible; }
.login-cloud-back { width: 47%; left: 51%; top: 9%; opacity: .55; }
.login-cloud-upper { width: 78%; left: -9%; top: 23%; opacity: .95; }
.login-cloud-middle { width: 57%; left: 45%; top: 48%; opacity: .8; }
.login-cloud-front { width: 91%; left: -18%; top: 68%; opacity: .95; }
.login-cloud-lower { width: 43%; left: 63%; top: 84%; opacity: .65; }
@media (max-width: 1023px) {
  .login-cloud-back { width: 28%; left: 72%; top: -18%; }
  .login-cloud-upper { width: 43%; left: -6%; top: 8%; }
  .login-cloud-middle { width: 33%; left: 40%; top: 38%; }
  .login-cloud-front { width: 42%; left: 4%; top: 72%; }
  .login-cloud-lower { width: 29%; left: 77%; top: 73%; }
}
@media (prefers-reduced-motion: reduce) {
  .login-cloud { animation: none; will-change: auto; }
}
`;

const clouds = [
  ["back", "login-cloud-b"],
  ["upper", ""],
  ["middle", "login-cloud-c"],
  ["front", "login-cloud-b"],
  ["lower", "login-cloud-c"],
];

export function LoginArt({ className }: { className?: string }) {
  const id = useId();
  return (
    <div
      data-testid="login-art"
      aria-hidden="true"
      className={cn("pointer-events-none select-none overflow-hidden bg-gradient-to-b from-[#60c6f2] to-[#E6F4F9]", className)}
    >
      <style>{LOGIN_ART_CSS}</style>
      {clouds.map(([layer, motion]) => (
        <svg
          key={layer}
          className={`login-cloud-shape login-cloud-${layer}`}
          viewBox="0 0 340 160"
          focusable="false"
          xmlns="http://www.w3.org/2000/svg"
        >
          <defs>
            <linearGradient id={`${id}-${layer}`} x1="0" y1="0" x2="0" y2="1">
              <stop offset="0" stopColor="#ffffff" />
              <stop offset="1" stopColor="#E6F4F9" />
            </linearGradient>
          </defs>
          <g className={`login-cloud ${motion}`} fill={`url(#${id}-${layer})`}>
            <path d="M70 138a46 46 0 0 1-4-92 62 62 0 0 1 120-6 50 50 0 0 1 83 33 34 34 0 1 1 16 65Z" />
          </g>
        </svg>
      ))}
    </div>
  );
}
