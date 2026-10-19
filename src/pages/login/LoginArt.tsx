import { cn } from "@/lib/utils";

// Arte decorativa da tela de login: nuvens em SVG inline (sem imagem, sem fonte
// extra), gradiente primary-light → secondary dos tokens nubo.* do app.
// Puramente decorativa: aria-hidden, sem captura de ponteiro, nada focável.
const LOGIN_ART_CSS = `
@keyframes login-cloud-drift {
  from { transform: translateX(-18px); }
  to   { transform: translateX(18px); }
}
.login-cloud { animation: login-cloud-drift 28s ease-in-out infinite alternate; transform-box: fill-box; }
.login-cloud-b { animation-duration: 36s; animation-direction: alternate-reverse; }
.login-cloud-c { animation-duration: 44s; }
@media (prefers-reduced-motion: reduce) {
  .login-cloud { animation: none; }
}
`;

function Cloud({ className, x, y, scale, opacity }: { className: string; x: number; y: number; scale: number; opacity: number }) {
  return (
    <g className={`login-cloud ${className}`} transform={`translate(${x} ${y}) scale(${scale})`} opacity={opacity} fill="url(#login-cloud-fill)">
      <circle cx="70" cy="90" r="46" />
      <circle cx="140" cy="62" r="62" />
      <circle cx="222" cy="86" r="50" />
      <circle cx="285" cy="104" r="34" />
      <rect x="30" y="96" width="290" height="42" rx="21" />
    </g>
  );
}

export function LoginArt({ className }: { className?: string }) {
  return (
    <div
      data-testid="login-art"
      aria-hidden="true"
      className={cn("pointer-events-none select-none overflow-hidden bg-gradient-to-b from-[#60c6f2] to-[#E6F4F9]", className)}
    >
      <style>{LOGIN_ART_CSS}</style>
      <svg
        className="h-full w-full"
        viewBox="0 0 600 800"
        preserveAspectRatio="xMidYMid slice"
        focusable="false"
        xmlns="http://www.w3.org/2000/svg"
      >
        <defs>
          <linearGradient id="login-cloud-fill" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0" stopColor="#ffffff" />
            <stop offset="1" stopColor="#E6F4F9" />
          </linearGradient>
        </defs>
        <Cloud className="" x={40} y={90} scale={1.25} opacity={0.95} />
        <Cloud className="login-cloud-b" x={250} y={300} scale={0.9} opacity={0.8} />
        <Cloud className="login-cloud-c" x={-30} y={520} scale={1.5} opacity={0.9} />
        <Cloud className="login-cloud-b" x={300} y={640} scale={0.7} opacity={0.65} />
      </svg>
    </div>
  );
}
