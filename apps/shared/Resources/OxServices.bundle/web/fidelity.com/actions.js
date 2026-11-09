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
     if(document.querySelector('#dom-username-input') && document.querySelector('#dom-pswd-input') && document.querySelector('#dom-login-button')) return null;
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
 action('login',{async invoke(){const s=await state();if(!s)return null; /* Preserve existing authentication rather than forcing a new login. */ return null;}});
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
