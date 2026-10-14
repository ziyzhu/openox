import { createContext, runInContext } from "node:vm";
import { createInterface } from "node:readline";

const lines = createInterface({ input: process.stdin });
let realm: ReturnType<typeof createContext> | undefined;
let started = false;
const emit = (value: unknown) => process.stdout.write(JSON.stringify(value) + "\n");
const evaluate = (source: string) => runInContext(source, realm!, { timeout: 1000 });
lines.on("line", line => {
  try {
    const message = JSON.parse(line);
    if (!started) {
      started = true;
      realm = createContext(Object.create(null), { codeGeneration: { strings: false, wasm: false } });
      evaluate(`
        const catalog = ${JSON.stringify(message.catalog)};
        const queue = [], pending = new Map(), logs = [];
        let serial = 0, finished = false, result, failure;
        const call = (name, args) => new Promise((resolve, reject) => { const id = ++serial; pending.set(id, {resolve,reject}); queue.push({id,name,args}); });
        const ox = {};
        for (const [name, contract] of Object.entries(catalog)) {
          const parts = name.split('.').slice(1); let target = ox;
          for (const part of parts.slice(0,-1)) target = target[part] ??= {};
          const fn = name === 'ox.provider.schema'
            ? () => { queue.push({name,args:{},inspection:true}); return JSON.parse(JSON.stringify(catalog['ox.provider.get'].outputSchema)); }
            : args => call(name, args);
          fn.help = () => JSON.stringify(contract);
          target[parts.at(-1)] = fn;
        }
        const help = (target, prefix) => {
          for (const [key,value] of Object.entries(target)) if (typeof value === 'object') help(value, prefix+'.'+key);
          Object.defineProperty(target, 'help', {value:()=>Object.keys(catalog).filter(name=>name.startsWith(prefix+'.')).join('\\n')});
        };
        help(ox,'ox');
        const console = Object.freeze(Object.fromEntries(['log','info','warn','error','debug'].map(level=>[level,(...args)=>logs.push(args.map(value=>typeof value==='string'?value:JSON.stringify(value)).join(' '))])));
        const settle = message => { const item=pending.get(message.id); if(!item) throw Error('Unknown response'); pending.delete(message.id); message.error ? item.reject(Object.assign(new Error(message.error.message),message.error)) : item.resolve(message.value); };
      `);
      evaluate(`(async()=>{${message.source}\n})().then(value=>{result=value;finished=true},error=>{failure={code:error.code??'execution_failed',message:error.message};finished=true});`);
    } else evaluate(`settle(${JSON.stringify(message)})`);
  } catch (error) { emit({ done: true, error: String(error), logs: [] }); process.exit(1); }
});
setInterval(() => {
  if (!realm) return;
  try {
    const state = JSON.parse(evaluate("JSON.stringify({calls:queue.splice(0),finished,result,failure,logs:logs.splice(0)})"));
    for (const call of state.calls) emit(call.inspection ? { inspection: call } : { call });
    if (state.logs.length) emit({ logs: state.logs });
    if (state.finished) { emit({ done: true, value: state.result, error: state.failure }); process.exit(0); }
  } catch (error) { emit({ done: true, error: String(error) }); process.exit(1); }
}, 1);
