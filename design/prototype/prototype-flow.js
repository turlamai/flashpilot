/* Simulated bench workflow with explicit confirmation and local evidence. */
(() => {
 const P=Prototype,{ $, $$, text, link, match, nav, go, modal, status, read, save, download, copy }=P;
 nav('.nav .item',{Bench:'bench.html',Plans:'plan.html',Flash:'confirm.html',Evidence:'evidence.html',Settings:'settings.html'});
 const file=location.pathname.split('/').pop();let plan=read('plan','plan.sim.json');
 const report=()=>({schema:'flashpilot.prototype.report/v1',simulated:true,plan,result:read('result','not-run'),steps:read('steps',[])});
 match('button',/Validate bench/,()=>modal('Bench validation','模拟台架就绪。未探测真实设备。',[],()=>go('plan.html'),'查看计划'));
 match('button',/Refresh status/,()=>status('模拟台架状态已刷新 · 未连接硬件'));
 match('button',/^Read DTCs/,()=>{const line=$('.dtc .mono');if(line)line.textContent='0 DTCs · simulated read '+new Date().toLocaleTimeString();status('演示诊断完成：0 个故障码')});
 match('button',/^Clear DTCs/,()=>modal('Clear simulated DTCs?','仅清空示例诊断，不访问 ECU。',[],()=>status('示例故障码已清空'),'Clear'));
 if(file==='bench.html')$$('.transport .row:not(.dim)').forEach(row=>link(row,()=>{if(!text(row).includes('Simulated')){modal('Hardware connection unavailable','此原型仅提供模拟台架；硬件选项用于展示支持级别，不会建立连接。');return}$$('.transport .row').forEach(x=>x.classList.toggle('selected',x===row))}));
 match('button',/^Choose plan/,()=>modal('Choose a sample plan','选择内置样本，不读取磁盘。',[{label:'Plan',name:'plan',options:['plan.sim.json','plan.sim-fd.json','plan.sim-missing-image.json']}],d=>{save('plan',d.plan);location.reload()},'选择'));
 if(file==='plan.html'){
   const rows=$$('.list .row');const update=()=>{rows.forEach(r=>r.classList.toggle('selected',text(r).includes(plan)));const fail=/missing|pdx/.test(plan);$('.detail .panel-h .tt').textContent='Verification — '+plan;$('.detail .panel-h .badge').textContent=fail?'blocked':'passed';$('.detail .panel-h .badge').className='badge '+(fail?'danger':'ok');$('.failcard').hidden=!fail;const flash=$$('button').find(b=>/Flash plan/.test(text(b)));flash.disabled=fail;flash.title=fail?'Plan has unresolved verification errors':'';save('verified',!fail);};
   rows.forEach(r=>link(r,()=>{plan=text($('.pname',r));save('plan',plan);update()}));update();
   match('button',/^Verify plan/,()=>{update();status(/missing|pdx/.test(plan)?'演示校验未通过：修复缺失镜像或选用模拟计划':'演示校验通过 · 0 错误 / 1 警告')});
   const fp=$$('.fp .mono');if(fp.length===2)fp[1].textContent='expected 144252e810505c9f';
 }
 match('button',/^Flash plan|^Flash again/,()=>go('confirm.html'));
 match('button',/^Cancel/,()=>go('plan.html'));
 if(file==='confirm.html'){
   const confirm=$('button.danger');const valid=read('verified',false);confirm.disabled=!valid;
   if(!valid){const note=$('.cap');if(note)note.textContent='请先在 Plans 验证计划。未通过验证时禁止开始演示。'}
   link(confirm,()=>{save('steps',[]);save('result','running');go('flash.html?run=1')});
   document.addEventListener('keydown',e=>{if(e.key==='Escape')go('plan.html');if(e.shiftKey&&e.key==='Enter'&&!confirm.disabled)confirm.click()});
 }
 if(file==='flash.html'){
   const steps=$$('.step'),badge=$('.head .badge');let n=0;
   if(new URLSearchParams(location.search).get('run')==='1'&&read('result')==='running'){
     const timer=setInterval(()=>{if(n<steps.length){const s=steps[n++];s.classList.add('done');const ic=$('.sic',s);if(ic)ic.textContent='✓';const sub=$('.sd',s);if(sub)sub.textContent='模拟完成';save('steps',steps.slice(0,n).map(s=>text($('.sn',s))));if(badge)badge.textContent=`SIMULATION · ${n}/${steps.length}`;}else{clearInterval(timer);save('result','passed');go('evidence.html?run=latest')}},350);
   }else{const btn=document.createElement('button');btn.className='btn primary';btn.textContent='开始新的演示（需确认）';link(btn,()=>go('plan.html'));$('.head')?.append(btn);}
 }
 if(file==='evidence.html'){
   if(new URLSearchParams(location.search).get('run')==='latest'&&read('result')==='passed'){
     const view=$('.view');view.replaceChildren();const card=document.createElement('div');card.className='panel';card.innerHTML='<h2>模拟刷写完成</h2><p>6 / 6 步骤通过 · 未访问真实 ECU</p><pre></pre>'; $('pre',card).textContent=JSON.stringify(report(),null,2);view.append(card);const b=document.createElement('button');b.className='btn';b.textContent='Copy report JSON';link(b,()=>copy(JSON.stringify(report(),null,2)));card.append(b);
   }else $$('.runrow').forEach(r=>link(r,()=>modal(text($('.rid',r)),'示例报告记录\n'+text(r)+'\n以下详情为失败记录的设计样本。')));
 }
 match('button',/^Re-run verify/,()=>go('plan.html'));
 match('button',/^Export/,()=>download('flashpilot-prototype-report.json',JSON.stringify(report(),null,2)));
 match('button',/^Copy report JSON/,()=>copy(JSON.stringify(report(),null,2)));
 match('button',/^Open folder/,()=>modal('Local report files','原型不打开系统目录；可以使用 Export all 下载本地演示报告。'));
 match('button',/^Choose…/,b=>modal('Report directory','只记录界面偏好，不写入该目录。',[{label:'路径',name:'path',required:true,value:read('directory','~/Bench/flashpilot-reports')}],d=>{save('directory',d.path);$('.pathbox',b.parentElement).textContent=d.path},'保存'));
 match('button',/^Reset to defaults/,()=>modal('Reset prototype preferences?','将恢复此原型的设置，演示报告保持不变。',[],()=>{save('dark',false);save('directory','~/Bench/flashpilot-reports');location.reload()},'Reset'));
 if(file==='settings.html'){P.choices('.seg');P.switches('.toggle');}
 document.addEventListener('keydown',e=>{if(e.target.closest('input,textarea,select,dialog')||e.metaKey||e.ctrlKey||e.altKey)return;const routes=['bench','plan','confirm','evidence'];if(/^[1-4]$/.test(e.key))go(routes[+e.key-1]+'.html');if(e.key==='?')modal('Keyboard shortcuts','1–4：切换页面\nV：校验计划\nF：进入确认\nE：下载演示报告\nEsc：取消确认');if(e.key==='v')go('plan.html');if(e.key==='f')go('confirm.html');if(e.key==='e')download('flashpilot-prototype-report.json',JSON.stringify(report(),null,2));});
})();
