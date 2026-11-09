window.ox.install(({ action }) => {
 const summaryUrl='https://digital.fidelity.com/ftgw/digital/portfolio/summary';
 const loginUrl='https://digital.fidelity.com/prgw/digital/signin/retail?AuthRedUrl=https%3A%2F%2Fdigital.fidelity.com%2Fftgw%2Fdigital%2Fportfolio%2Fsummary';
 const groupIds=new Set(['allaccounts','IA','RA','SP','HS']);
 const text = el => (el.textContent || '').replace(/\s+/g,' ').trim();
 async function state() {
   const deadline=Date.now()+20000;
   while(Date.now()<deadline) {
     const all=document.querySelector('.acct-selector__acct-list #allaccounts');
     const rows=[...document.querySelectorAll('.acct-selector__acct-list a[id]')].filter(x=>!groupIds.has(x.id) && /balance:/.test(text(x)));
     const logout=[...document.querySelectorAll('a')].some(x=>text(x)==='Log Out');
     if(all && rows.length && logout && /balance:\s*\$[0-9]/.test(text(all))) return {all,rows};
     if((document.querySelector('#dom-username-input') || document.querySelector('#dom-select-username')) && document.querySelector('#dom-pswd-input') && document.querySelector('#dom-login-button')) return null;
     await new Promise(r=>setTimeout(r,200));
   }
   throw new Error('Fidelity portfolio or signed-out login state did not become ready. Authentication, verification, or page structure needs inspection.');
 }
 async function descriptor(s) {
   const bytes=new TextEncoder().encode(s.rows.map(x=>x.id).sort().join('|'));
   const hash=[...new Uint8Array(await crypto.subtle.digest('SHA-256',bytes))].map(x=>x.toString(16).padStart(2,'0')).join('');
   return {id:'portfolio-'+hash,label:'Fidelity portfolio '+hash.slice(0,6),url:summaryUrl};
 }
 function balance(el) {const match=text(el).match(/balance:\s*\$([0-9,]+(?:\.[0-9]+)?)/);if(!match)throw new Error('Fidelity balance format unavailable');return Number(match[1].replace(/,/g,''));}
 action('listSessions',{async invoke(){const s=await state();return s?[await descriptor(s)]:[];}});
 const cleanText = value => String(value ?? "").replace(/\s+/g, " ").trim();

const usable = element => {
  if (!element || element.disabled || element.readOnly || element.type === "hidden") return false;
  if (element.closest("[hidden], [aria-hidden='true'], [inert]")) return false;
  const style = getComputedStyle(element);
  return style.display !== "none" && style.visibility !== "hidden";
};

const waitForStep = async (detectors, timeout = 15000) => {
  const end = Date.now() + timeout;
  while (Date.now() < end) {
    for (const [kind, detect] of Object.entries(detectors)) {
      const match = detect();
      if (match) return { kind, match };
    }
    await new Promise(resolve => setTimeout(resolve, 200));
  }
  return { kind: "unknown", match: null };
};

const typeInto = (field, value) => {
  field.focus();
  field.select?.();
  if (!document.execCommand("insertText", false, value) || field.value !== value) {
    Object.getOwnPropertyDescriptor(Object.getPrototypeOf(field), "value").set.call(field, value);
    field.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertText", data: value }));
  }
  field.dispatchEvent(new Event("change", { bubbles: true }));
};

const pageError = (root = document) => [...root.querySelectorAll("[role='alert'], [aria-live='assertive'], [aria-live='polite']")]
  .filter(usable)
  .map(element => cleanText(element.innerText))
  .filter(Boolean)
  .join(" | ")
  .slice(0, 200);
const fidelityLoginStep=async()=>waitForStep({challenge:()=>[...document.querySelectorAll('input[autocomplete="one-time-code"],iframe[src*="captcha"]')].find(usable),anotherUsername:()=>{const select=document.getElementById('dom-select-username');if(!usable(select))return null;const index=[...select.options].findIndex(o=>cleanText(o.textContent)==='Enter different username');return index>=0?{select,index}:null;},credentials:()=>{const username=document.getElementById('dom-username-input'),password=document.getElementById('dom-pswd-input'),submit=document.getElementById('dom-login-button'),root=username?.closest('form');return usable(username)&&usable(password)&&usable(submit)&&root?.contains(password)&&root?.contains(submit)?{username,password,submit,root}:null;},signedIn:()=>document.querySelector('.acct-selector__acct-list #allaccounts')});
action('login',{async invoke(input,context){const step=await fidelityLoginStep();if(step.kind==='unknown'&&!input?.account)throw Error('Fidelity login screen not recognized; automatic login stopped.');if(!input?.account||input.account.serviceID!=='web:fidelity.com')return null;if(step.kind==='anotherUsername'){step.match.select.selectedIndex=step.match.index;step.match.select.dispatchEvent(new Event('change',{bubbles:true}));return null;}if(step.kind!=='credentials')return null;if(pageError(step.match.root))throw Error('Fidelity sign-in reports an error; stopped without retrying.');const account=await context.secret(input.account);if(!step.match.username.isConnected||!step.match.password.isConnected)return null;typeInto(step.match.username,account.username);typeInto(step.match.password,account.password);if(!usable(step.match.submit))throw Error('Fidelity login button unavailable.');step.match.submit.click();return null;}});

 action('getPortfolioSummary',{async invoke(){
   const s=await state();if(!s)throw new Error('Fidelity sign-in required');
   let category='Other';const accounts=[];
   for(const row of document.querySelectorAll('.acct-selector__acct-list a[id]')) {
     if(groupIds.has(row.id)){if(row.id!=='allaccounts')category=text(row).split(',')[0];continue;}
     if(!/balance:/.test(text(row)))continue;
     let name=text(row).split(/,?\s*balance:/)[0].trim();
     name=name.split(row.id).join('').replace(/\b[A-Z]?[0-9]{5,}\b/g,'').replace(/\s+/g,' ').trim();
     accounts.push({name,category,balance:balance(row)});
   }
   return {totalBalance:balance(s.all),currency:'USD',observedAt:new Date().toISOString(),accounts,note:'Displayed Fidelity values; stock-plan and investment balances may overlap. Not a real-time quote or an additive account total.'};
 }});
 action('listPositions',{async invoke() {
   const s=await state();if(!s)throw new Error('Fidelity sign-in required');
   if(location.pathname!=='/ftgw/digital/portfolio/positions'){
     throw new Error('Invoke listPositions with pageUrl https://digital.fidelity.com/ftgw/digital/portfolio/positions to select the holdings page.');
   }
   const deadline=Date.now()+30000;let root,rows;
   while(Date.now()<deadline){root=document.querySelector('.positions-content');rows=root?[...root.querySelectorAll('.ag-center-cols-container .ag-row')]:[];if(rows.some(x=>x.classList.contains('posweb-row-position')) && !root.querySelector('.ag-overlay-loading-center'))break;await new Promise(r=>setTimeout(r,200));}
   if(!rows?.some(x=>x.classList.contains('posweb-row-position')))throw new Error('Fidelity holdings did not load');
   const num=v=>{const match=(v||'').replace(/[$,\s]/g,'').replace(/−/g,'-').match(/[+-]?[0-9]+(?:\.[0-9]+)?/);return match?Number(match[0]):null;};
   const items=[];let account='Account',accountIndex=0;
   for(const row of rows){const idx=row.getAttribute('row-index');const pinned=root.querySelector('.ag-pinned-left-cols-container .ag-row[row-index="'+idx+'"]');
     if(row.classList.contains('posweb-row-account')){accountIndex++;const label=pinned?.querySelector('.posweb-cell-account_primary');account=(label?text(label):'Account').replace(/\b[A-Z]?[0-9]{5,}\b/g,'').trim()+' (account '+accountIndex+')';continue;}
     if(!row.classList.contains('posweb-row-position'))continue;
     const symbolEl=pinned?.querySelector('.posweb-cell-symbol-name_container > span');
     const descEl=pinned?.querySelector('.posweb-cell-symbol-description');
     const symbol=symbolEl?text(symbolEl):(row.classList.contains('posweb-row-core')?'Cash':'');
     if(!symbol)throw new Error('Fidelity holding symbol unavailable');
     const cell=id=>row.querySelector('[col-id="'+id+'"]');
     items.push({account,symbol,description:descEl?text(descEl):'',quantity:num(cell('qty')?.textContent),currentValue:num(cell('curVal')?.textContent),totalGainLoss:num(cell('totGLStk')?.querySelector('.posweb-cell-stack-item-total_gl_currency')?.textContent),totalGainLossPercent:num(cell('totGLStk')?.querySelector('.posweb-cell-stack-item-total_gl_percent')?.textContent),pricingNote:pinned?.querySelector('.posweb-cell-a11y_indicator')?.textContent.trim()||''});
   }
   const expected=Number(root.querySelector('[role="grid"]')?.getAttribute('aria-rowcount'))-1;
   const limit=args.limit||100;
   return {items:items.slice(0,limit),nextCursor:null,coverage:'Rendered positions only; '+rows.length+' of '+expected+' grid rows loaded. '+(items.length>limit?'Output limited. ':'')+'Workplace retirement and unvested stock-plan holdings may not be included. Values may not be priced today.',observedAt:new Date().toISOString()};
 }});

});
