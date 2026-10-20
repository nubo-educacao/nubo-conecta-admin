import type { InstrumentationCoverage } from '@/types/productAnalytics';
export interface FunnelChartStep {
 key:string;label:string;value:number|null;
 /** Only disjoint event counts may be stacked. Unique people overlap. */
 composition?:{label:string;value:number}[];
 coverage?:InstrumentationCoverage;notInstrumented?:boolean;
}
export interface FunnelChartProps {
 steps:FunnelChartStep[];mode:'observed_volumes'|'sequential_cohort';rateBase?:'previous'|'first';
 unitLabel:string;height?:number;emptyLabel?:string;
}
export function FunnelChart({steps,mode,rateBase='previous',unitLabel,height,emptyLabel='Sem dados observados'}:FunnelChartProps){
 const maximum=Math.max(0,...steps.map(s=>s.value??0));
 const title=mode==='observed_volumes'?'Funil de volumes observados':'Funil de coorte sequencial';
 if(!steps.length)return <p>{emptyLabel}</p>;
 return <div role="img" aria-label={title+' — '+unitLabel} style={height?{minHeight:height}:undefined} className="space-y-4">
 {steps.map((step,index)=>{
  const base=steps[rateBase==='first'?0:index-1]?.value;
  const unavailable=step.notInstrumented||['unknown','not_instrumented','partial'].includes(step.coverage?.status??'');
  const ratio=index>0&&step.value!==null&&base!==null&&base!==undefined&&base>0&&!unavailable?step.value/base*100:null;
  const additive=unitLabel==='eventos'&&step.composition&&step.composition.length<=2&&step.value!==null&&step.composition.every(p=>p.value>=0)&&step.composition.reduce((sum,p)=>sum+p.value,0)===step.value;
  return <div key={step.key} data-testid="funnel-step" data-step={step.key}>
   <div className="flex flex-wrap justify-between gap-2 text-sm"><span>{step.label}</span><span>{step.value===null?'—':step.value.toLocaleString('pt-BR')}</span></div>
   <div className="mt-1 h-8 rounded bg-slate-100 overflow-hidden">
    <div className="flex h-full rounded bg-nubo-primary" style={{width:maximum>0&&step.value!==null?step.value/maximum*100+'%':'0%',...(unavailable?{backgroundImage:'repeating-linear-gradient(135deg, transparent, transparent 5px, rgba(0,0,0,.25) 5px, rgba(0,0,0,.25) 7px)'}:{})}}>
     {additive&&step.composition?.map((part,i)=><div key={part.label} title={part.label+': '+part.value} className={i===0?'bg-nubo-primary':'bg-nubo-primary-dark'} style={{width:step.value?part.value/step.value*100+'%':'0%'}} />)}
    </div>
   </div>
   {unavailable&&<p className="text-xs text-slate-600">{step.notInstrumented||step.coverage?.status==='not_instrumented'?'Não instrumentado':step.coverage?.status==='partial'?'Cobertura parcial — volume observado':'Cobertura desconhecida — volume observado'}</p>}
   {ratio!==null&&<p className="text-xs text-slate-600">{mode==='observed_volumes'?'Razão de volumes observados':'Conversão da coorte'}: {ratio.toLocaleString('pt-BR',{maximumFractionDigits:1})}%</p>}
   {step.composition&&<ul className="flex flex-wrap gap-3 text-xs">{step.composition.map(p=><li key={p.label}>{p.label}: {p.value.toLocaleString('pt-BR')}</li>)}</ul>}
  </div>;
 })}
 </div>;
}
