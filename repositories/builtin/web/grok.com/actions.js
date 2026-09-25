const pause=ms=>new Promise(r=>setTimeout(r,ms));
const visible=e=>e&&e.getClientRects().length>0;
const editor=()=>[...document.querySelectorAll('[contenteditable="true"][role="textbox"]')].find(e=>visible(e)&&e.getAttribute('aria-disabled')!=='true');
const id=()=>location.pathname.match(/^\/c\/([a-zA-Z0-9-]+)/)?.[1]||null;
async function wait(fn,ms=8000){const end=Date.now()+ms;do{const v=fn();if(v)return v;await pause(150);}while(Date.now()<end);throw new Error('Grok interface not ready; no automatic retry.');}
async function session(){const r=await fetch('/rest/user-settings',{credentials:'include',cache:'no-store'});if(r.redirected)throw new Error('Unexpected session redirect');const j=await r.json();if(r.status===401&&typeof j.code==='number'&&typeof j.message==='string')return {signedIn:false};if(r.status===401&&typeof j.code==='string'&&typeof j.message==='string')return {signedIn:false};if(r.status===200&&typeof j.enableMemory==='boolean'&&typeof j.excludeFromTraining==='boolean')return {signedIn:true};throw new Error('Unrecognized Grok session response: '+r.status);}
function read(status='rendered'){return {conversationId:id(),url:location.href,messages:[...document.querySelectorAll('.message-bubble')].filter(visible).slice(-200).map(e=>({role:e.className.includes('wd-user-bubble')?'user':'assistant',text:e.innerText.trim()})),status};}
async function send(prompt){
 const e=await wait(editor);const t=e.editor;
 if(!t?.commands?.insertContent||!t.state?.doc)throw new Error('Grok editor API unavailable; nothing submitted.');
 if(t.state.doc.textContent.trim()||e.textContent.trim())throw new Error('Existing draft present; refusing to overwrite.');
 const initialId=id();const oldNodes=new Set(document.querySelectorAll('.message-bubble'));
 e.focus();
 if(!t.commands.insertContent(prompt))throw new Error('Editor rejected prompt; nothing submitted.');
 await wait(()=>t.state.doc.textContent.trim()===prompt.trim()&&e.textContent.trim()===prompt.trim(),2000);
 await pause(800);
 if(t.state.doc.textContent.trim()!==prompt.trim()||e.textContent.trim()!==prompt.trim())throw new Error("Draft changed before submit.");
 const button=await wait(()=>{const b=document.querySelector('button[data-testid="chat-submit"][aria-label="Submit"]');return visible(b)&&!b.disabled&&b.getAttribute('aria-disabled')!=='true'?b:null;},3000);
 const form=e.closest('form');if(!form||typeof form.requestSubmit!=='function')throw new Error('Grok submit form unavailable');form.requestSubmit();
 const end=Date.now()+14000;
 while(Date.now()<end){
   const fresh=[...document.querySelectorAll('.message-bubble')].filter(n=>!oldNodes.has(n));
   const user=fresh.find(n=>n.className.includes('wd-user-bubble')&&n.textContent.trim()===prompt.trim());
   const target=id();
   if(user&&target&&(!initialId||target===initialId)){
     const result=read('accepted');return {...result,submissionConfirmed:true};
   }
   await pause(250);
 }
 return {...read('uncertain'),submissionConfirmed:false};
}
async function serverRead(conversationId){
 const request=async(path,options={})=>{const controller=new AbortController();const timer=setTimeout(()=>controller.abort(),8000);try{const r=await fetch(path,{...options,credentials:'include',cache:'no-store',signal:controller.signal});if(!r.ok||r.redirected)throw new Error('Grok message read failed: '+r.status);return await r.json();}finally{clearTimeout(timer);}};
 const root='/rest/app-chat/conversations/'+encodeURIComponent(conversationId);
 const index=await request(root+'/response-node');
 if(!Array.isArray(index.responseNodes)||!Array.isArray(index.inflightResponses))throw new Error('Unexpected Grok message index');
 const nodes=index.responseNodes;if(nodes.length>200)throw new Error('Conversation exceeds the current 200-message read limit');
 const children=new Map();for(const n of nodes){if(typeof n.responseId!=='string')throw new Error('Invalid response identifier');if(n.parentResponseId){children.set(n.parentResponseId,(children.get(n.parentResponseId)||0)+1);}}
 if([...children.values()].some(n=>n>1))throw new Error('Branched conversations are not yet supported by server reads');
 if(!nodes.length)return {conversationId,url:'https://grok.com/c/'+encodeURIComponent(conversationId),messages:[],status:index.inflightResponses.length?'pending':'complete'};
 const data=await request(root+'/load-responses',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({responseIds:nodes.map(n=>n.responseId)})});
 if(!Array.isArray(data.responses))throw new Error('Unexpected Grok response body');
 const byId=new Map(data.responses.map(r=>[r.responseId,r]));
 const responses=nodes.map(n=>{const r=byId.get(n.responseId);if(!r||typeof r.message!=='string'||!['human','assistant'].includes(r.sender))throw new Error('Incomplete or unsupported Grok message');return r;});
 responses.sort((a,b)=>String(a.createTime).localeCompare(String(b.createTime)));
 return {conversationId,url:'https://grok.com/c/'+encodeURIComponent(conversationId),messages:responses.map(r=>({role:r.sender==='human'?'user':'assistant',text:r.message})),status:index.inflightResponses.length||responses.some(r=>r.partial)?'pending':'complete'};
}
async function openTarget(conversationId){
  await wait(editor);
  if(id()!==conversationId){
    if(editor().innerText.trim())throw new Error('Existing draft present; refusing to navigate away.');
    const oldNodes=[...document.querySelectorAll('.message-bubble')];
    const a=await wait(()=>[...document.querySelectorAll('a[href]')].find(e=>new URL(e.href).pathname==='/c/'+conversationId));
    a.click();
    await wait(()=>id()===conversationId&&editor()&&oldNodes.every(e=>!e.isConnected)&&[...document.querySelectorAll('.message-bubble')].some(visible));
  }else{await wait(()=>editor()&&[...document.querySelectorAll('.message-bubble')].some(visible));}
  if(id()!==conversationId)throw new Error('Conversation changed during loading.');
  return read();
}
window.ox.install(({action})=>{
action('searchConversations',{async invoke({query}){if(!query.trim())throw Error('Search query must not be blank');const r=await fetch('/rest/app-chat/conversations?pageSize=60&searchQuery='+encodeURIComponent(query),{credentials:'include',cache:'no-store'});if(!r.ok||r.redirected)throw Error('Grok search failed: '+r.status);const j=await r.json();if(!Array.isArray(j.conversations)||j.conversations.some(x=>typeof x.conversationId!=='string'||typeof x.title!=='string'))throw Error('Unexpected Grok search response');if(j.nextPageToken)throw Error('Grok returned more search results; continuation is not yet verified. Narrow the query.');return {items:j.conversations.map(x=>({id:x.conversationId,title:x.title,url:'https://grok.com/c/'+encodeURIComponent(x.conversationId)})),nextCursor:null};}});
action('getInterfaceState',{async invoke(){const e=await wait(editor);const b=document.querySelector('button[data-testid="chat-submit"]');const text=e.editor?.state?.doc?.textContent;return {path:location.pathname,editorPresent:!!e,domLength:e.textContent.trim().length,stateLength:typeof text==='string'?text.trim().length:-1,testDraftMatches:text?.trim()==='Reply exactly OX_GROK_OK',messageCount:document.querySelectorAll('.message-bubble').length,submitPresent:!!b,submitDisabled:!b||b.disabled,sidebarIds:[...document.querySelectorAll('a[href]')].map(a=>new URL(a.href).pathname).filter(p=>p.startsWith('/c/')).slice(0,60)};}});
action('getSignInUrl',{invoke:async()=>({url:'https://grok.com/sign-in?return_to=%2F'})});
action('getSignInState',{invoke:session});
action('listConversations',{async invoke({limit=20}){const r=await fetch('/rest/app-chat/conversations?pageSize='+limit,{credentials:'include',cache:'no-store'});if(!r.ok||r.redirected)throw new Error('Conversation request failed: '+r.status);const j=await r.json();if(!Array.isArray(j.conversations))throw new Error('Unexpected conversation response');return {items:j.conversations.map(c=>({conversationId:c.conversationId,title:c.title||'',url:'https://grok.com/c/'+encodeURIComponent(c.conversationId),createTime:c.createTime||null,modifyTime:c.modifyTime||null})),nextCursor:j.nextPageToken||null};}});
action('openConversation',{invoke:({conversationId})=>openTarget(conversationId)});
action('getCurrentConversation',{invoke:({conversationId})=>serverRead(conversationId)});
action('chat',{async invoke({prompt}){await wait(editor);if(editor().innerText.trim())throw new Error('Existing draft present; refusing to navigate away.');if(location.pathname!=='/'){const a=[...document.querySelectorAll('a[href="/"]')].find(e=>visible(e));if(!a)throw new Error('New-chat control unavailable');a.click();await wait(()=>location.pathname==='/'&&editor()&&!document.querySelector('.message-bubble'));}return send(prompt);}});
action('continueChat',{async invoke({conversationId,prompt}){await openTarget(conversationId);if(id()!==conversationId)throw new Error('Conversation changed before submission.');return send(prompt);}});
});
