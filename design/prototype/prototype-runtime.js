/* Local prototype interactions; never connects to a product backend. */
(() => {
  'use strict';
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => [...r.querySelectorAll(s)];
  const text = el => el?.textContent.trim() || '';
  const esc = s => String(s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const segments = location.pathname.split('/').filter(Boolean);
  const rawIndex = segments.lastIndexOf('raw');
  const project = rawIndex > 0 ? segments[rawIndex - 1] : segments[segments.length - 3];
  const key = project + ':prototype:';
  const read = (k, fallback) => { try { return JSON.parse(localStorage.getItem(key + k)) ?? fallback; } catch { return fallback; } };
  const save = (k, v) => { try { localStorage.setItem(key + k, JSON.stringify(v)); return true; } catch { return false; } };
  const style = document.createElement('style');
  style.textContent = `[hidden]{display:none!important}button:disabled{opacity:.5;cursor:not-allowed}.proto-link{cursor:pointer!important}.proto-link:focus-visible{outline:2px solid var(--accent,currentColor);outline-offset:3px}.proto-dialog{font:14px/1.6 system-ui,sans-serif;width:min(520px,calc(100vw - 32px));max-height:85vh;overflow:auto;border:1px solid var(--line,#bbb);border-radius:12px;padding:24px;background:var(--surface,#fff);color:var(--ink,#222);box-shadow:0 20px 80px #0004}.proto-dialog::backdrop{background:#0006}.proto-dialog h2{font-size:20px;margin:0 0 12px}.proto-dialog p{white-space:pre-wrap}.proto-dialog label{display:grid;gap:6px;margin:16px 0}.proto-dialog input,.proto-dialog select,.proto-dialog textarea{font:inherit;color:inherit;background:var(--bg,#fff);border:1px solid var(--line,#bbb);padding:10px;border-radius:6px;width:100%}.proto-dialog textarea{min-height:110px}.proto-actions{display:flex;gap:10px;justify-content:flex-end;margin-top:22px}.proto-dialog button{font:inherit;padding:8px 16px;border:1px solid var(--line,#bbb);border-radius:7px;color:inherit;background:var(--bg,#fafafa);cursor:pointer}.proto-dialog button[type=submit]{background:var(--accent,#a94e31);color:white}.proto-status{position:fixed;z-index:99999;bottom:20px;left:50%;transform:translateX(-50%);max-width:calc(100vw - 32px);background:var(--ink,#222);color:var(--surface,#fff);padding:10px 18px;border-radius:8px;box-shadow:0 4px 20px #0003;font:13px/1.5 system-ui}.proto-result{padding:16px;color:var(--mute,#666)}.proto-context{display:flex;gap:20px;padding:10px 16px;font:12px system-ui;color:var(--mute,#666)}.proto-context a{color:var(--accent,inherit)}`;
  document.head.append(style);
  let timer;
  function status(s) { let el=$('#prototype-status'); if(!el){el=document.createElement('div');el.id='prototype-status';el.className='proto-status';el.setAttribute('role','status');document.body.append(el)} el.textContent=s;el.hidden=false;clearTimeout(timer);timer=setTimeout(()=>el.hidden=true,4200); }
  function link(el, action) { if(!el)return;el.classList.add('proto-link');if(!el.matches('button,a,input,select,textarea')){el.tabIndex=0;el.setAttribute('role','button');el.addEventListener('keydown',e=>{if(e.key==='Enter'||e.key===' '){e.preventDefault();e.stopPropagation();el.click()}})}el.addEventListener('click',e=>{e.preventDefault();action(el,e)}); }
  function match(selector, pattern, action) { $$(selector).filter(el=>pattern.test(text(el)||el.title||el.getAttribute('aria-label')||'')).forEach(el=>link(el,action)); }
  const go = file => { location.href = file; };
  function nav(selector, mapping) { $$(selector).forEach(el=>{const label=text(el).replace(/\s+/g,' ');const route=Object.entries(mapping).find(([name])=>label.includes(name));if(route)link(el,()=>go(route[1]));}); }
  function modal(title, body, fields=[], done=null, submit='确认') {
    const trigger=document.activeElement;const dialog=document.createElement('dialog');dialog.className='proto-dialog';dialog.setAttribute('aria-label',title);
    dialog.innerHTML=`<form><h2>${esc(title)}</h2><p>${esc(body)}</p>${fields.map(f=>`<label>${esc(f.label)}${f.options?`<select name="${esc(f.name)}">${f.options.map(v=>`<option${v===f.value?' selected':''}>${esc(v)}</option>`).join('')}</select>`:f.type==='textarea'?`<textarea name="${esc(f.name)}" ${f.required?'required':''}>${esc(f.value||'')}</textarea>`:`<input name="${esc(f.name)}" type="${esc(f.type||'text')}" value="${esc(f.value||'')}" ${f.required?'required':''} ${f.min!==undefined?`min="${f.min}"`:''} ${f.max!==undefined?`max="${f.max}"`:''} autocomplete="off">`}</label>`).join('')}<div class="proto-actions"><button type="button" data-close autofocus>${done?'取消':'关闭'}</button>${done?`<button type="submit">${esc(submit)}</button>`:''}</div></form>`;
    document.body.append(dialog);$('[data-close]',dialog).onclick=()=>dialog.close();$('form',dialog).onsubmit=e=>{e.preventDefault();const data=Object.fromEntries(new FormData(e.target));if(done?.(data)===false)return;dialog.close()};dialog.onclose=()=>{dialog.remove();if(trigger?.isConnected)trigger.focus()};dialog.showModal();return dialog;
  }
  function download(name, contents, type='application/json'){const url=URL.createObjectURL(new Blob([contents],{type})),a=document.createElement('a');a.href=url;a.download=name;a.click();setTimeout(()=>URL.revokeObjectURL(url),1000)}
  async function copy(s){try{await navigator.clipboard.writeText(s);status('已复制')}catch{modal('复制内容','剪贴板不可用，请选择以下内容复制。',[{label:'内容',name:'copy',type:'textarea',value:s}])}}
  function choices(selector) { $$(selector).forEach(group=>{[...group.children].filter(x=>x.tagName==='SPAN'&&!x.children.length).forEach(el=>{el.setAttribute('aria-pressed',el.classList.contains('on'));link(el,()=>{[...group.children].forEach(x=>{x.classList.toggle('on',x===el);x.setAttribute('aria-pressed',x===el)});if(/^(Auto|System|Light|Dark)$/i.test(text(el))){const dark=/dark/i.test(text(el))||/auto|system/i.test(text(el))&&matchMedia('(prefers-color-scheme:dark)').matches;($('#app')||document.body).classList.toggle('dark',dark);save('dark',dark)}})})}) }
  function switches(selector) { $$(selector).forEach(el=>{if(el.parentElement.querySelector('.locknote')){el.setAttribute('aria-disabled','true');el.title='固定保护，不可关闭';return}el.setAttribute('role','switch');el.setAttribute('aria-checked',el.classList.contains('on'));link(el,()=>{el.classList.toggle('on');el.setAttribute('aria-checked',el.classList.contains('on'))})}) }
  const app=$('#app')||document.body;
  if(read('dark',false))app.classList.add('dark');
  $('#themeBtn')?.addEventListener('click',()=>save('dark',app.classList.contains('dark')));
  $$('button').forEach(b=>{if(!text(b)&&!b.getAttribute('aria-label'))b.setAttribute('aria-label',b.title||'操作')});
  window.Prototype={$, $$, text, esc, read, save, status, link, match, go, nav, modal, download, copy, choices, switches};
})();
