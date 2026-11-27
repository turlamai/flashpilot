/* Simulated bench workflow with explicit confirmation and local evidence. */
(() => {
 const P=Prototype,{ $, $$, text, link, match, nav, go, modal, status, read, save, download, copy }=P;
 nav('.nav .item',{Bench:'bench.html',Plans:'plan.html',Flash:'confirm.html',Evidence:'evidence.html',Settings:'settings.html'});
 const file=location.pathname.split('/').pop();let plan=read('plan','plan.sim.json');
 const runKey='flash-run-v2';
 const currentRun=()=>read(runKey,null);
 const report=()=>({schema:'flashpilot.prototype.report/v1',simulated:true,...(currentRun()||{plan:null,result:'not-run',steps:[]})});
 const verified=()=>read('verified-plan',null)===read('plan','plan.sim.json')&&!/missing|pdx/.test(read('plan','plan.sim.json'));
 const selectPlan=value=>{if(value!==read('plan','plan.sim.json'))save('verified-plan',null);save('plan',value);};
 match('button',/Validate bench/,()=>modal('Bench validation','The simulated bench is ready. No real hardware was probed.',[],()=>go('plan.html'),'View plans'));
 match('button',/Refresh status/,()=>status('Simulated bench status refreshed · no hardware connected'));
 match('button',/^Read DTCs/,()=>{const line=$('.dtc .mono');if(line)line.textContent='0 DTCs · simulated read '+new Date().toLocaleTimeString();status('Demo diagnostics complete: 0 DTCs')});
 match('button',/^Clear DTCs/,()=>modal('Clear simulated DTCs?','Clears the sample diagnostics only; the ECU is not accessed.',[],()=>status('Sample DTCs cleared'),'Clear'));
 if(file==='bench.html')$$('.transport .row:not(.dim)').forEach(row=>link(row,()=>{if(!text(row).includes('Simulated')){modal('Hardware connection unavailable','This prototype offers the simulated bench only; the hardware options show support levels and never establish a connection.');return}$$('.transport .row').forEach(x=>x.classList.toggle('selected',x===row))}));
 match('button',/^Choose plan/,()=>modal('Choose a sample plan','Pick a bundled sample; nothing is read from disk.',[{label:'Plan',name:'plan',options:['plan.sim.json','plan.sim-fd.json','plan.sim-missing-image.json']}],d=>{selectPlan(d.plan);location.reload()},'Choose'));
 if(file==='plan.html'){
   const rows=$$('.list .row');const update=(verify=false)=>{rows.forEach(r=>r.classList.toggle('selected',text(r).includes(plan)));const fail=/missing|pdx/.test(plan);if(verify)save('verified-plan',fail?null:plan);const ready=!fail&&verified();$('.detail .panel-h .tt').textContent='Verification — '+plan;$('.detail .panel-h .badge').textContent=fail?'blocked':ready?'passed':'not verified';$('.detail .panel-h .badge').className='badge '+(fail?'danger':ready?'ok':'');$('.failcard').hidden=!fail;const flash=$$('button').find(b=>/Flash plan/.test(text(b)));flash.disabled=!ready;flash.title=fail?'Plan has unresolved verification errors':ready?'':'Verify this plan first';};
   rows.forEach(r=>link(r,()=>{plan=text($('.pname',r));selectPlan(plan);update()}));update();
   match('button',/^Verify plan/,()=>{update(true);status(/missing|pdx/.test(plan)?'Demo verification failed: restore the missing image or pick a simulator plan':'Demo verification passed · 0 errors / 1 warning')});
   const fp=$$('.fp .mono');if(fp.length===2)fp[1].textContent='expected 144252e810505c9f';
 }
 match('button',/^Flash plan|^Flash again/,()=>go('confirm.html'));
 match('button',/^Cancel/,()=>go('plan.html'));
 if(file==='confirm.html'){
   const confirm=$('button.danger');const valid=verified()&&currentRun()?.result!=='running';confirm.disabled=!valid;
   if(!valid){const note=$('.cap');if(note)note.textContent='Verify a plan in Plans first. The demo cannot start while the plan is unverified.'}
   link(confirm,()=>{if(!verified()||currentRun()?.result==='running'){status('Verify the current plan and finish the previous run first');return}const run={id:Date.now().toString(36),plan:read('plan','plan.sim.json'),result:'running',steps:[],total:null};if(!save(runKey,run)){status('Local storage unavailable; simulation not started');return}go('flash.html?run='+encodeURIComponent(run.id))});
   document.addEventListener('keydown',e=>{if(e.target.closest('input,textarea,select,dialog,[contenteditable]')||e.repeat||document.querySelector('dialog[open]'))return;if(e.key==='Escape')go('plan.html');if(e.shiftKey&&e.key==='Enter'&&!confirm.disabled)confirm.click()});
 }
 if(file==='flash.html'){
   const steps=$$('.step'),badge=$('.head .badge');const run=currentRun();
   const requested=new URLSearchParams(location.search).get('run');
   if(run?.result==='running'&&requested===run.id){
     const resumed=run.total!==null;
     run.total=steps.length;
     let n=run.steps.length;
     const draw=(s)=>{s.classList.add('done');const ic=$('.sic',s);if(ic)ic.textContent='✓';const sub=$('.sd',s);if(sub)sub.textContent='simulated complete';};
     steps.slice(0,n).forEach(draw);
     if(resumed)status('Resumed simulated run from saved progress');
     save(runKey,run);
     const timer=setInterval(()=>{const latest=currentRun();if(latest?.id!==run.id||latest.result!=='running'){clearInterval(timer);status('Run is no longer active');return}if(latest.steps.length>n)n=latest.steps.length;
       if(n<steps.length){draw(steps[n++]);run.steps=steps.slice(0,n).map(s=>text($('.sn',s)));if(!save(runKey,run)){clearInterval(timer);status('Cannot save progress; reopen to resume');return}if(badge)badge.textContent='SIMULATION · '+n+'/'+steps.length;}
       else{clearInterval(timer);run.steps=steps.map(s=>text($('.sn',s)));run.result='passed';if(save(runKey,run))go('evidence.html?run=latest');else status('Cannot save report; reopen to resume');}
     },350);
   }else{const btn=document.createElement('button');btn.className='btn primary';btn.textContent=run?.result==='running'?'Resume saved simulation':'Start a new demo (confirm required)';link(btn,()=>go(run?.result==='running'?'flash.html?run='+encodeURIComponent(run.id):'plan.html'));$('.head')?.append(btn);}

 }
 if(file==='evidence.html'){
   if(new URLSearchParams(location.search).get('run')==='latest'&&currentRun()?.result==='passed'){
     const view=$('.view');view.replaceChildren();const card=document.createElement('div');card.className='panel';card.innerHTML='<h2>Simulated flash complete</h2><p></p><pre></pre>'; $('p',card).textContent=report().steps.length+' / '+report().total+' steps passed · no real ECU accessed'; $('pre',card).textContent=JSON.stringify(report(),null,2);view.append(card);const b=document.createElement('button');b.className='btn';b.textContent='Copy report JSON';link(b,()=>copy(JSON.stringify(report(),null,2)));card.append(b);
   }else $$('.runrow').forEach(r=>link(r,()=>modal(text($('.rid',r)),'Sample report record\n'+text(r)+'\nThe details below are a design sample of the failed run.')));
 }
 match('button',/^Re-run verify/,()=>go('plan.html'));
 match('button',/^Export/,()=>download('flashpilot-prototype-report.json',JSON.stringify(report(),null,2)));
 match('button',/^Copy report JSON/,()=>copy(JSON.stringify(report(),null,2)));
 match('button',/^Open folder/,()=>modal('Local report files','The prototype does not open system folders; use Export all to download the local demo report.'));
 match('button',/^Choose…/,b=>modal('Report directory','Records the interface preference only; nothing is written to that folder.',[{label:'Path',name:'path',required:true,value:read('directory','~/Bench/flashpilot-reports')}],d=>{save('directory',d.path);$('.pathbox',b.parentElement).textContent=d.path},'Save'));
 match('button',/^Reset to defaults/,()=>modal('Reset prototype preferences?',"Restores this prototype's settings; demo reports are kept.",[],()=>{save('dark',false);save('directory','~/Bench/flashpilot-reports');location.reload()},'Reset'));
 if(file==='settings.html'){P.choices('.seg');P.switches('.toggle');}
 document.addEventListener('keydown',e=>{if(e.target.closest('input,textarea,select,dialog,[contenteditable]')||document.querySelector('dialog[open]')||e.repeat||e.metaKey||e.ctrlKey||e.altKey)return;const routes=['bench','plan','confirm','evidence'];if(/^[1-4]$/.test(e.key))go(routes[+e.key-1]+'.html');if(e.key==='?')modal('Keyboard shortcuts','1–4: switch section\nV: verify plan\nF: open confirm\nE: download demo report\nEsc: cancel confirm');if(e.key==='v')go('plan.html');if(e.key==='f')go('confirm.html');if(e.key==='e')download('flashpilot-prototype-report.json',JSON.stringify(report(),null,2));});
})();
