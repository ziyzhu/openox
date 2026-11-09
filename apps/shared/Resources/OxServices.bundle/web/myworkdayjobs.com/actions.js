
async function discoverAuthenticatedSessions(){if(location.hostname!=='nvidia.wd5.myworkdayjobs.com')throw Error('Only the NVIDIA Workday tenant is verified');const r=await fetch('/wday/cxs/nvidia/NVIDIAExternalCareerSite/userprofile',{credentials:'include',cache:'no-store'});if(!r.ok)throw Error('Workday session HTTP '+r.status);const j=await r.json();if(typeof j.candidateId==='string'&&j.candidateId&&typeof j.emailAddress==='string'&&j.emailAddress&&j.person&&typeof j.canUpdateContactInformation==='boolean')return [{id:location.hostname+':'+j.candidateId,label:j.emailAddress,url:"https://nvidia.wd5.myworkdayjobs.com/en-US/NVIDIAExternalCareerSite/login"}];if(j&&typeof j==='object'&&!Array.isArray(j)&&Object.keys(j).length===0)return [];throw Error('Unclassified Workday identity response');}
const clean=x=>String(x??'').replace(/\s+/g,' ').trim();
const wait=async f=>{const end=Date.now()+23000;while(Date.now()<end){const v=f();if(v)return v;await new Promise(r=>setTimeout(r,180));}throw Error('Workday expected form controls did not become ready');};
const ready=async()=>{if(!location.pathname.endsWith('/apply')){const a=await wait(()=>document.querySelector('[data-automation-id="continueButton"]'));a.click();}await wait(()=>{const h=[...document.querySelectorAll('h2,h3')].map(x=>clean(x.innerText)).join(' | ');if(h.includes('My Information')){const c=document.getElementById('country--country');return c&&(clean(c.innerText)==='Select One'||document.getElementById('name--legalName--firstName'));}if(h.includes('My Experience'))return document.querySelector('input[id^="education-"]')&&document.querySelector('[data-automation-id="file-upload-item-name"]');if(h.includes('Application Questions'))return document.querySelector('[id^="primaryQuestionnaire--"]');if(h.includes('Voluntary Disclosures'))return document.getElementById('personalInfoUS--ethnicity')&&document.getElementById('termsAndConditions--acceptTermsAndAgreements');if(h.includes('Review'))return [...document.querySelectorAll('button')].some(x=>clean(x.innerText)==='Submit');return false;});};
const snap=()=>({url:location.href,context:(/Review/.test([...document.querySelectorAll('h2,h3')].map(x=>x.innerText).join(' '))?clean((document.querySelector('main')||document.querySelector('[role="main"]'))?.innerText).slice(0,22000):[...document.querySelectorAll('[data-automation-id]')].filter(x=>/^(formField-|resumeAttachments|workExperience|education|file-upload|attachment)/i.test(x.getAttribute('data-automation-id'))).map(x=>x.getAttribute('data-automation-id')+': '+clean(x.innerText)).join(' | ').slice(0,22000)),step:clean([...document.querySelectorAll('h2,h3')].map(x=>x.innerText).join(' | ')),fields:[...document.querySelectorAll('input,select,textarea,button[id]')].filter(x=>(x.id||x.getAttribute('data-automation-id'))&&!['password','hidden'].includes(x.type)&&!['accountSettingsButton','hammyMenuIcon'].includes(x.id)).map(x=>({id:x.id||'',automation:x.getAttribute('data-automation-id')||'',label:clean(x.getAttribute('aria-label')||[...document.querySelectorAll('label')].find(l=>l.htmlFor===x.id&&x.id)?.innerText||''),type:x.type||x.tagName.toLowerCase(),value:x.tagName==='BUTTON'?clean(x.innerText):['checkbox','radio'].includes(x.type)?String(x.checked):x.value||''})),buttons:[...document.querySelectorAll('button')].map(x=>clean(x.innerText)).filter(Boolean),errors:[...document.querySelectorAll('[role="alert"],[data-automation-id="errorMessage"]')].map(x=>clean(x.innerText)).filter(x=>x&&!/successfully uploaded/i.test(x)).concat([...document.querySelectorAll('[aria-invalid="true"]')].map(x=>'Invalid field: '+(x.id||x.getAttribute('aria-label')||x.tagName)))});
window.ox.install(({ action }) => {
action('listSessions',{async invoke(){return discoverAuthenticatedSessions();}});
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
const workdayLoginStep=async()=>waitForStep({challenge:()=>[...document.querySelectorAll('input[autocomplete="one-time-code"],iframe[src*="captcha"]')].find(usable),credentials:()=>{const root=document.querySelector('[data-automation-id="signInFormo"]'),username=root?.querySelector('input[data-automation-id="email"]'),password=root?.querySelector('input[data-automation-id="password"]'),submit=root?.querySelector('[role="button"][aria-label="Submit"]');return usable(username)&&usable(password)&&usable(submit)?{root,username,password,submit}:null;},emailOption:()=>{const e=document.querySelector('[data-automation-id="SignInWithEmailButton"]');return usable(e)&&cleanText(e.textContent)==='Sign in with email'?e:null;}});
action('login',{async invoke(input,context){const step=await workdayLoginStep();if(step.kind==='unknown'&&!input?.account)throw Error('Workday login screen not ready; automatic login stopped.');if(!input?.account||input.account.serviceID!=='web:myworkdayjobs.com')return null;if(step.kind==='emailOption'){step.match.click();return null;}if(step.kind!=='credentials')return null;if(pageError(step.match.root))throw Error('Workday sign-in reports an error; stopped without retrying.');const account=await context.secret(input.account);typeInto(step.match.username,account.username);typeInto(step.match.password,account.password);if(!usable(step.match.submit))throw Error('Workday sign-in submit control unavailable.');step.match.submit.click();return null;}});

action('getApplication',{async invoke(){await ready();return snap();}});
action('updateField',{async invoke({id,value}){await ready();const e=document.getElementById(id)||[...document.querySelectorAll('[data-automation-id]')].find(x=>x.getAttribute('data-automation-id')===id);if(!e)throw Error('Inspected field not found');if(e.matches('[data-automation-id^="formField-"]')){const label=[...e.querySelectorAll('label')].find(l=>clean(l.innerText)===value);const radio=label&&document.getElementById(label.htmlFor);if(!radio||radio.type!=='radio')throw Error('Exact radio choice not found');if(!radio.checked)radio.click();}else if(e.tagName==='BUTTON'){if(e.type==='submit'||/submit|save|continue|delete|remove/i.test(e.innerText))throw Error('Not a choice field');e.click();const opt=await wait(()=>[...document.querySelectorAll('[role="option"]')].find(x=>clean(x.innerText)===value));opt.click();await wait(()=>clean(e.innerText)===value); }else{if(!['INPUT','TEXTAREA','SELECT'].includes(e.tagName)||['password','file','hidden'].includes(e.type))throw Error('Unsupported field type');if(e.type==='checkbox'){if(e.checked!==(value==='true'))e.click();}else{const proto=e.tagName==='TEXTAREA'?HTMLTextAreaElement.prototype:e.tagName==='SELECT'?HTMLSelectElement.prototype:HTMLInputElement.prototype;Object.getOwnPropertyDescriptor(proto,'value').set.call(e,value);e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}));e.blur();}}return snap();}});
action('saveAndContinue',{async invoke(){await ready();const before=snap();if(/Review/.test(before.step))throw Error('Stopped at Review; submission is intentionally unsupported');const e=document.querySelector('[data-automation-id="pageFooterNextButton"]');if(clean(e?.innerText)!=='Save and Continue')throw Error('Expected Save and Continue only');e.click();await wait(()=>snap().step!==before.step||snap().errors.length);await ready();return snap();}});
});