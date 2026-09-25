const BOOT='/edge-api/bootstrap?statsig_hashing_algorithm=djb2&growthbook_format=sdk&cache_bust=1&include_system_prompts=false';
const pause=ms=>new Promise(r=>setTimeout(r,ms));
async function json(path){const r=await fetch(path,{credentials:'include',cache:'no-store'});if(r.redirected||r.status!==200)throw Error('Claude request failed: HTTP '+r.status);if(!(r.headers.get('content-type')||'').includes('json'))throw Error('Unexpected Claude response type');return r.json();}
async function account(){const j=await json(BOOT);if(j.account===null)return null;if(j.account&&typeof j.account.uuid==='string'&&Array.isArray(j.account.memberships))return j.account;throw Error('Unrecognized Claude session response');}
async function org(id){const a=await account();if(!a)throw Error('Sign in to Claude first');const ms=a.memberships.map(x=>x.organization).filter(x=>x&&typeof x.uuid==='string');if(id){if(!ms.some(x=>x.uuid===id))throw Error('Organization is not available to this account');return id;}if(ms.length!==1)throw Error('Choose an organizationId from getCurrentUser');return ms[0].uuid;}
const url=id=>'https://claude.ai/chat/'+id;
const summary=j=>({id:j.uuid,title:j.name||'',model:j.model||null,url:url(j.uuid),updatedAt:j.updated_at||null});
async function detail(organizationId,id){const o=await org(organizationId);const j=await json('/api/organizations/'+encodeURIComponent(o)+'/chat_conversations/'+encodeURIComponent(id)+'?tree=True&rendering_mode=messages&render_all_tools=true&include_inline_comparison=true&consistency=strong');if(j.uuid!==id||!Array.isArray(j.chat_messages))throw Error('Conversation identity or message shape mismatch');return {id:j.uuid,title:j.name||'',model:j.model||null,url:url(j.uuid),messages:j.chat_messages.map(m=>({id:m.uuid,parentId:m.parent_message_uuid||null,role:m.sender,text:typeof m.text==='string'&&m.text?m.text:(m.content||[]).filter(c=>c.type==='text'&&typeof c.text==='string').map(c=>c.text).join('\n'),createdAt:m.created_at||null}))};}
const visible=e=>!!e&&e.getClientRects().length>0;
async function wait(fn,ms=7000){const end=Date.now()+ms;while(Date.now()<end){const v=fn();if(v)return v;await pause(120);}throw Error('Claude interface not ready; no submission retried');}
const editor=()=>{const e=document.querySelector('[data-testid="chat-input"][contenteditable="true"]');return visible(e)?e:null;};
const picker=()=>document.querySelector('[data-testid="model-selector-dropdown"]');
const modelOptions=()=>Array.from(document.querySelectorAll('[role="menuitemradio"]')).filter(e=>visible(e)&&/^(Opus|Sonnet|Haiku)\s/.test(e.innerText.trim()));
const modelName=e=>e.innerText.trim().split('\n')[0].trim();
async function openModels(){await wait(editor);const p=await wait(()=>visible(picker())&&picker());if(p.getAttribute('aria-expanded')!=='true')p.click();await wait(()=>modelOptions().length);let prior='',since=Date.now();const end=Date.now()+4000;while(Date.now()<end){const key=modelOptions().map(modelName).join('|');if(key!==prior){prior=key;since=Date.now();}if(key&&Date.now()-since>=700)return modelOptions();await pause(100);}return modelOptions();}
function closeModels(){const p=picker();if(p&&p.getAttribute('aria-expanded')==='true')p.click();}
function conversationId(){return location.pathname.match(/^\/chat\/([a-f0-9-]{36})$/)?.[1]||null;}
async function send(message,target,organizationId){
 const organization=await org(organizationId);
 const baseline=target?await detail(organization,target):null;
 const known=new Set(baseline?baseline.messages.map(m=>m.id):[]);
 await wait(editor,5000);
 if(target){const link=await wait(()=>Array.from(document.querySelectorAll('a[href]')).find(a=>new URL(a.href,location.href).pathname==='/chat/'+target),3000);link.click();const lastHuman=baseline.messages.filter(m=>m.role==='human').pop();await wait(()=>{const users=Array.from(document.querySelectorAll('[data-testid="user-message"]'));const assistants=Array.from(document.querySelectorAll('[data-testid="assistant-message"]'));return conversationId()===target&&editor()&&(!lastHuman||users.at(-1)?.innerText.trim()===lastHuman.text.trim())&&(!assistants.length||assistants.at(-1).getAttribute('data-is-streaming')==='false');},6000);
 }else if(location.pathname!=='/new')throw Error('Expected a fresh new-chat page');
 const e=await wait(editor,2000);if(e.innerText.trim())throw Error('Existing draft present; refusing to overwrite it');if(!message.trim())throw Error('Message must not be blank');
 e.focus();if(!document.execCommand('insertText',false,message))throw Error('Unable to enter message; nothing submitted');
 const button=await wait(()=>{const b=document.querySelector('[data-testid="chat-input-send"]');return editor()?.innerText.trim()===message.trim()&&visible(b)&&!b.disabled&&b.getAttribute('aria-disabled')!=='true'?b:null;},2500);
 button.click();
 const end=Date.now()+12000;let confirmed=false;let observedId=null;
 while(Date.now()<end){const id=conversationId();if(id&&(!target||id===target)){observedId=id;try{const state=await detail(organization,id);const sent=state.messages.find(m=>m.role==='human'&&!known.has(m.id)&&m.text.trim()===message.trim());if(sent){confirmed=true;const reply=state.messages.find(m=>m.role==='assistant'&&!known.has(m.id)&&m.parentId===sent.id);const elements=Array.from(document.querySelectorAll('[data-testid="assistant-message"]'));const last=elements.at(-1);if(reply?.text&&last?.getAttribute('data-is-streaming')==='false'&&last.innerText.includes(reply.text.trim()))return {status:'response_available',conversationId:id,url:url(id),response:reply.text};}}catch(error){console.log('Claude response read pending');}}await pause(600);}
 return {status:confirmed?'submitted_pending':'submission_unconfirmed',conversationId:observedId,url:location.href,response:null};
}
window.ox.install(({action})=>{
 action('getSignInUrl',{async invoke(){return {url:'https://claude.ai/login'};}});
 action('getSignInState',{async invoke(){return {signedIn:(await account())!==null};}});
 action('getCurrentUser',{async invoke(){const a=await account();if(!a)throw Error('Sign in to Claude first');return {id:a.uuid,name:a.full_name||a.display_name||'',email:a.email_address||'',organizations:a.memberships.map(m=>({id:m.organization.uuid,name:m.organization.name||''}))};}});
 action('listConversations',{async invoke({organizationId,limit=20,cursor='0'}){const o=await org(organizationId),offset=Number(cursor);if(!Number.isSafeInteger(offset)||offset<0)throw Error('Invalid cursor');const j=await json('/api/organizations/'+encodeURIComponent(o)+'/chat_conversations_v2?limit='+limit+'&offset='+offset+'&archived=false&consistency=eventual');if(!Array.isArray(j.data)||typeof j.has_more!=='boolean')throw Error('Unexpected conversation list');if(j.has_more&&j.data.length===0)throw Error('Source pagination stalled');return {items:j.data.map(summary),nextCursor:j.has_more?String(offset+j.data.length):null};}});
 action('searchConversations',{async invoke({organizationId,query}){if(!query.trim())throw Error('Search query must not be blank');const o=await org(organizationId);const j=await json('/api/organizations/'+encodeURIComponent(o)+'/conversation/search/v2?query='+encodeURIComponent(query)+'&n=25&target_snippet_size=100');if(!Array.isArray(j.data)||typeof j.degraded!=='boolean'||typeof j.executed_mode!=='string')throw Error('Unexpected search response');if(j.next_page_token!==null)throw Error('Source returned continuation; search pagination is not supported yet');return {items:j.data.map(x=>summary(x.conversation)),nextCursor:null,degraded:j.degraded,mode:j.executed_mode};}});
 action('getConversation',{async invoke({organizationId,conversationId}){return detail(organizationId,conversationId);}});
 action('listModels',{async invoke(){const items=(await openModels()).map(e=>({name:modelName(e),selected:e.getAttribute('aria-checked')==='true'}));closeModels();return {items,nextCursor:null};}});
 action('selectModel',{async invoke({name}){await openModels();let option;try{option=await wait(()=>modelOptions().find(e=>modelName(e)===name),4000);}catch(e){closeModels();throw Error('Requested model is not a selectable displayed option');}option.click();await wait(()=>picker()?.innerText.includes(name));return {selected:name};}});
 action('chat',{async invoke({message,organizationId}){return send(message,null,organizationId);}});
 action('continueChat',{async invoke({message,conversationId,organizationId}){return send(message,conversationId,organizationId);}});
});
